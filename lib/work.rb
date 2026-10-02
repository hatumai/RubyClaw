# frozen_string_literal: true
# Operational state that lives outside the conversation.
#
# The chat history is context, not the source of truth. These four files are the truth,
# and everything else (notifications, responsibilities, a heartbeat) will read them:
#
#   data/work.json       tasks      -- what is being worked on, and in what state
#   data/events.jsonl    events     -- append-only: every change, dated and attributed
#   data/artifacts.json  artifacts  -- the work products, each tied to a task
#   data/approvals.json  approvals  -- what is waiting on a human
#   data/responsibilities.json  standing commitments -- an objective plus triggers
#   data/pending-events.json    the unified event inbox the heartbeat drains
#
# Same shape as Schedule, deliberately: JSON on disk (not SQLite -- the driver is a gem
# and this project ships no gems), read-modify-write under one flock so two processes
# cannot corrupt a store, writes through a temp file and a rename so a reader sees the
# old store or the new one and never half of either, fsync before the rename so a power
# cut cannot leave an empty file where a valid one was, and a sweep for temp files a
# crash left behind.
#
# A task's state is one of eight (STATES). Moves go through `set_state`, which consults
# ALLOWED and refuses anything not on the list: a DONE task does not quietly become
# WORKING again -- reopening is `reopen`, an explicit call that says so in the log. Every
# accepted move, and every creation, is one line in the event log, so a task's whole
# history is reconstructable from the log alone.
require "json"
require "time"
require "fileutils"
require "securerandom"

module RubyClaw
  module Work
    TASKS     = File.join(ROOT, "data", "work.json")
    EVENTS    = File.join(ROOT, "data", "events.jsonl")
    ARTIFACTS = File.join(ROOT, "data", "artifacts.json")
    APPROVALS = File.join(ROOT, "data", "approvals.json")
    # Two more stores in the same shape, for the standing commitments and the pending
    # unified events the heartbeat drains (stage C). They share the one lock and the
    # atomic-write discipline with the rest.
    RESPONSIBILITIES = File.join(ROOT, "data", "responsibilities.json")
    INBOX     = File.join(ROOT, "data", "pending-events.json")
    # The notification store: the outbound queue for messages that could not be sent,
    # the dedupe ledger that keeps a pending approval from being re-announced every
    # pass, the withheld-digest tally, and how far the event log has been scanned for
    # things worth telling a person (stage D, lib/notify.rb). The heartbeat's own
    # last-pass record sits beside it.
    NOTIFICATIONS = File.join(ROOT, "data", "notifications.json")
    HEARTBEAT_STATE = File.join(ROOT, "data", "heartbeat.json")
    LOCK      = File.join(ROOT, "data", "work.lock")

    # The eight states (gap 7). The first six are open; the last two are terminal and
    # are only left by an explicit reopen, which is the point of having terminal states.
    STATES = %w[QUEUED THINKING WORKING WAITING BLOCKED NEEDS_APPROVAL DONE FAILED].freeze
    # A failed attempt is retried this many times, then the task is FAILED. The count
    # is durable (task["attempts"]), so a crash cannot reset it and a stuck task cannot
    # be retried forever. The wait between attempts grows with the count.
    RETRY_LIMIT = 3
    RETRY_BACKOFF = 60
    # The inbox ledger is capped so it cannot grow without bound; the binding "one event,
    # one task" guarantee is the task's event_key, which survives the ledger forgetting.
    HANDLED_MAX = 1000
    OPEN_STATES = (STATES - %w[DONE FAILED]).freeze
    # Anything a human has to look at: shown first by the view, in the order that matters.
    ATTENTION = %w[BLOCKED NEEDS_APPROVAL].freeze

    ARTIFACT_STATUS = %w[draft current superseded].freeze
    APPROVAL_DECISIONS = %w[granted denied].freeze

    # The legal moves, as data rather than a chain of ifs, so the rule is one thing to read
    # and one thing to test. A task moves freely among the open states -- that is what the
    # work is doing -- with one refusal and one absence:
    #
    #   * QUEUED straight to DONE is refused: a task that was never started was never
    #     finished, and a status that says otherwise hides work nobody did.
    #   * DONE and FAILED have no outgoing moves at all. Reopening is `reopen`, which is an
    #     explicit act and leaves a line in the event log saying a person reopened it.
    ALLOWED = {
      "QUEUED"         => %w[THINKING WORKING WAITING BLOCKED NEEDS_APPROVAL FAILED],
      "THINKING"       => %w[QUEUED WORKING WAITING BLOCKED NEEDS_APPROVAL DONE FAILED],
      "WORKING"        => %w[QUEUED THINKING WAITING BLOCKED NEEDS_APPROVAL DONE FAILED],
      "WAITING"        => %w[QUEUED THINKING WORKING BLOCKED NEEDS_APPROVAL DONE FAILED],
      "BLOCKED"        => %w[QUEUED THINKING WORKING WAITING NEEDS_APPROVAL DONE FAILED],
      "NEEDS_APPROVAL" => %w[QUEUED THINKING WORKING WAITING BLOCKED DONE FAILED],
      "DONE"           => [],
      "FAILED"         => []
    }.freeze

    class << self
      # ---- the rule ---------------------------------------------------------

      def normalize_state(state)
        s = state.to_s.strip.upcase
        return s if STATES.include?(s)

        raise Error, "unknown state #{state.inspect}; states are #{STATES.join(', ')}"
      end

      # Pure: does the rule allow this move? Used by set_state and tested directly, so the
      # rule can be exercised for all 64 pairs without a process per pair.
      def transition_allowed?(from, to)
        ALLOWED.fetch(from.to_s.strip.upcase, []).include?(to.to_s.strip.upcase)
      end

      # ---- primitives: the lock, the atomic write, the sweep ----------------

      # A crash between writing a temp file and renaming it leaves the temp file behind and
      # nothing else will ever touch it. Only sweeps files old enough to be dead: another
      # writer's temp file is live, and deleting it between its write and its rename loses
      # that writer's task. Five minutes is far longer than a rename takes.
      STALE_TMP = 300

      def sweep_temp!
        [TASKS, ARTIFACTS, APPROVALS, RESPONSIBILITIES, INBOX, NOTIFICATIONS, HEARTBEAT_STATE].each do |store|
          Dir["#{store}.*.tmp"].each do |f|
            next unless (Time.now - File.mtime(f)) > STALE_TMP

            File.unlink(f) rescue nil
          end
        end
      rescue StandardError
        nil
      end

      # One lock for all three read-modify-write stores. Every writer goes through it, so
      # two processes can add a task at the same instant and both survive.
      def with_lock
        sweep_temp!
        FileUtils.mkdir_p(File.dirname(LOCK))
        File.open(LOCK, File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          yield
        end
      end

      def write_json(path, key, list)
        FileUtils.mkdir_p(File.dirname(path))
        tmp = "#{path}.#{Process.pid}.tmp"
        File.open(tmp, "w") do |f|
          f.write(JSON.pretty_generate(key => list, "updated" => Time.now.utc.iso8601) + "\n")
          f.fsync
        end
        File.rename(tmp, path)      # a reader sees the old file or the new one, never half
      end

      # Valid JSON of the wrong shape used to raise a bare TypeError from deep inside the
      # caller. Say what is wrong and what to do, as Schedule does.
      def read_json(path, key)
        return [] unless File.exist?(path)

        data = begin
          JSON.parse(File.read(path))
        rescue JSON::ParserError => e
          raise Error, "#{path} is not valid JSON (#{e.message}); fix or delete it"
        end
        unless data.is_a?(Hash) && data[key].is_a?(Array)
          raise Error, "#{path} is not a #{key} list (expected {\"#{key}\": [...]}); fix or delete it"
        end

        data[key]
      end

      # One line per event, appended under the lock so two processes cannot interleave a
      # line. Append-only: nothing here rewrites or truncates the log.
      def emit(event)
        FileUtils.mkdir_p(File.dirname(EVENTS))
        line = JSON.generate(event.merge("ts" => Time.now.utc.iso8601))
        File.open(EVENTS, "a") do |f|
          f.write(line + "\n")
          f.fsync
        end
        line
      end

      def new_id(prefix) = "#{prefix}-#{SecureRandom.hex(6)}"

      # ---- tasks ------------------------------------------------------------

      def tasks = read_json(TASKS, "tasks")
      def save_tasks(list) = write_json(TASKS, "tasks", list)
      def find_task(id) = tasks.find { |t| t["id"] == id.to_s }

      # A new task is QUEUED; anything else is a state that was reached, not a state it
      # started in, and reaching it goes through set_state (which logs it).
      #
      # responsibility_id links the task to the standing commitment it serves, event_key
      # links it to the one event that created it; both are optional and only written
      # when given (an ordinary hand-made task has neither key).
      def add_task(title:, project: nil, detail: nil, owner: nil, responsibility_id: nil,
                   event_key: nil, skill: nil, now: Time.now)
        title = title.to_s.strip
        raise Error, "a task needs a title" if title.empty?

        task = new_task_record(title: title, project: project, detail: detail, owner: owner,
                               responsibility_id: responsibility_id, event_key: event_key,
                               skill: skill, now: now)
        with_lock do
          list = tasks
          list << task
          save_tasks(list)
          emit("kind" => "task.created", "task_id" => task["id"], "state" => "QUEUED",
               "title" => title)
        end
        task
      end

      # The fields of a new task, shared by add_task and add_task_once so the two cannot
      # drift apart.
      def new_task_record(title:, project: nil, detail: nil, owner: nil, responsibility_id: nil,
                          event_key: nil, skill: nil, now: Time.now)
        task = {
          "id" => new_id("t"),
          "title" => title.to_s.strip,
          "state" => "QUEUED",
          "project" => blank_to_nil(project),
          "owner" => blank_to_nil(owner),
          "detail" => blank_to_nil(detail),
          "note" => nil,
          "created" => now.utc.iso8601,
          "updated" => now.utc.iso8601
        }
        task["responsibility_id"] = blank_to_nil(responsibility_id) if responsibility_id
        task["event_key"] = blank_to_nil(event_key) if event_key
        task["skill"] = blank_to_nil(skill) if skill
        task
      end

      # One event becomes at most one task, ever. The dedupe and the create happen in the
      # same critical section, so two processes replaying the same event at the same
      # instant cannot both create a task -- the second finds the first's task by
      # event_key and returns it. Returns [task, created]; created is false when the
      # event already had a task and nothing was written.
      def add_task_once(title:, event_key:, project: nil, detail: nil, owner: nil,
                        responsibility_id: nil, skill: nil, now: Time.now)
        title = title.to_s.strip
        raise Error, "a task needs a title" if title.empty?

        event_key = event_key.to_s.strip
        raise Error, "add_task_once needs an event_key (the idempotence key)" if event_key.empty?

        result = nil
        with_lock do
          list = tasks
          existing = list.find { |t| t["event_key"] == event_key }
          if existing
            result = [existing, false]
          else
            task = new_task_record(title: title, project: project, detail: detail, owner: owner,
                                   responsibility_id: responsibility_id, event_key: event_key,
                                   skill: skill, now: now)
            list << task
            save_tasks(list)
            emit("kind" => "task.created", "task_id" => task["id"], "state" => "QUEUED",
                 "title" => task["title"], "event_key" => event_key,
                 "responsibility_id" => blank_to_nil(responsibility_id))
            result = [task, true]
          end
        end
        result
      end

      # The task an event already made, if it made one. The event key is the durable link
      # between an event and the single task it is allowed to create.
      def task_for_event(event_key) = tasks.find { |t| t["event_key"] == event_key.to_s }

      def tasks_for_responsibility(id) = tasks.select { |t| t["responsibility_id"] == id.to_s }

      # The one way a task changes state. Refuses an illegal move rather than recording it,
      # and appends the accepted one to the log.
      def set_state(id, to, note: nil, now: Time.now)
        to = normalize_state(to)
        result = nil
        with_lock do
          list = tasks
          task = list.find { |t| t["id"] == id.to_s } or raise Error, "no task #{id}"
          from = task["state"]
          unless transition_allowed?(from, to)
            raise Error, "refusing to move task #{id} from #{from} to #{to}#{move_hint(from, to)}"
          end

          task["state"] = to
          task["note"] = blank_to_nil(note)
          task["updated"] = now.utc.iso8601
          save_tasks(list)
          emit("kind" => "task.state", "task_id" => task["id"], "from" => from, "to" => to,
               "note" => blank_to_nil(note))
          result = task
        end
        result
      end

      # The only way out of DONE or FAILED, and it says so in the log. Refused for anything
      # that is still open: there is nothing to reopen.
      def reopen(id, note: nil, now: Time.now)
        result = nil
        with_lock do
          list = tasks
          task = list.find { |t| t["id"] == id.to_s } or raise Error, "no task #{id}"
          from = task["state"]
          unless %w[DONE FAILED].include?(from)
            raise Error, "task #{id} is #{from}, not finished; only a DONE or FAILED task can be reopened"
          end

          task["state"] = "QUEUED"
          task["note"] = blank_to_nil(note)
          task["updated"] = now.utc.iso8601
          save_tasks(list)
          emit("kind" => "task.reopened", "task_id" => task["id"], "from" => from, "to" => "QUEUED",
               "note" => blank_to_nil(note))
          result = task
        end
        result
      end

      # Change what a task says about itself, without a state move. Anything not passed is
      # left alone; at least one field has to be passed.
      #
      # The scheduling fields are what the heartbeat reads: depends_on (another task this
      # one waits for), resume_at / retry_at (times at which a WAITING or BLOCKED task may
      # move again) and deadline (when it needs a person).
      def update_task(id, title: nil, project: nil, detail: nil, owner: nil, depends_on: nil,
                      deadline: nil, resume_at: nil, retry_at: nil, retry_limit: nil, now: Time.now)
        result = nil
        with_lock do
          list = tasks
          task = list.find { |t| t["id"] == id.to_s } or raise Error, "no task #{id}"
          changed = []
          { "title" => title, "project" => project, "detail" => detail, "owner" => owner,
            "depends_on" => depends_on, "deadline" => deadline, "resume_at" => resume_at,
            "retry_at" => retry_at }.each do |k, v|
            next if v.nil?

            task[k] = k == "title" ? v.to_s.strip : blank_to_nil(v)
            changed << k
          end
          unless retry_limit.nil?
            task["retry_limit"] = retry_limit.to_i
            changed << "retry_limit"
          end
          raise Error, "nothing to update on task #{id}" if changed.empty?

          task["updated"] = now.utc.iso8601
          save_tasks(list)
          emit("kind" => "task.updated", "task_id" => task["id"], "fields" => changed)
          result = task
        end
        result
      end

      # One failed attempt at a task's work. The count is durable, and past retry_limit the
      # task is marked FAILED -- so a stuck task is retried a bounded number of times and
      # then stops, rather than being retried forever. A retried task goes back to QUEUED
      # (one of the ordinary eight states) with a retry_at the heartbeat will honour; a
      # given-up one is FAILED, with the count in the log. Refused for a task that is
      # already terminal: nothing is retried after it has failed for good.
      def record_retry(id, note: nil, now: Time.now)
        result = nil
        with_lock do
          list = tasks
          task = list.find { |t| t["id"] == id.to_s } or raise Error, "no task #{id}"
          from = task["state"]
          if %w[DONE FAILED].include?(from)
            raise Error, "task #{id} is #{from}; a finished task is not retried"
          end

          task["attempts"] = task["attempts"].to_i + 1
          limit = (task["retry_limit"] || RETRY_LIMIT).to_i
          task["updated"] = now.utc.iso8601
          if task["attempts"] >= limit
            task["state"] = "FAILED"
            task["note"] = blank_to_nil(note) || "failed after #{task['attempts']} attempt(s)"
            save_tasks(list)
            emit("kind" => "task.state", "task_id" => task["id"], "from" => from, "to" => "FAILED",
                 "note" => task["note"])
            emit("kind" => "task.retries_exhausted", "task_id" => task["id"],
                 "attempts" => task["attempts"])
          else
            task["state"] = "QUEUED" if from != "QUEUED"
            task["note"] = blank_to_nil(note)
            task["retry_at"] = (now + (RETRY_BACKOFF * task["attempts"])).utc.iso8601
            save_tasks(list)
            if from != "QUEUED"
              emit("kind" => "task.state", "task_id" => task["id"], "from" => from, "to" => "QUEUED",
                   "note" => blank_to_nil(note))
            end
            emit("kind" => "task.retry", "task_id" => task["id"], "attempts" => task["attempts"],
                 "retry_at" => task["retry_at"])
          end
          result = task
        end
        result
      end

      def move_hint(from, to)
        return "; use `reopen` to put it back in the queue" if %w[DONE FAILED].include?(from)
        return "; a task that was never started cannot be finished" if from == "QUEUED" && to == "DONE"
        return " (it is already #{from})" if from == to

        "; allowed from #{from}: #{ALLOWED.fetch(from, []).join(', ')}"
      end

      # ---- artifacts --------------------------------------------------------

      def artifacts = read_json(ARTIFACTS, "artifacts")
      def save_artifacts(list) = write_json(ARTIFACTS, "artifacts", list)
      def find_artifact(id) = artifacts.find { |a| a["id"] == id.to_s }
      def artifacts_for(task_id) = artifacts.select { |a| a["task_id"] == task_id.to_s }

      # An artifact is the work product, not a chat message claiming one exists: it has a
      # type, a location and the task it came from. A task_id that names no task is refused,
      # because a link to nothing is worse than no link.
      def register_artifact(type:, title:, location:, task_id: nil, project: nil, created_by: nil,
                            version: nil, status: "draft", now: Time.now)
        type = type.to_s.strip
        title = title.to_s.strip
        location = location.to_s.strip
        raise Error, "an artifact needs a type (report, file, patch, url, ...)" if type.empty?
        raise Error, "an artifact needs a title" if title.empty?
        raise Error, "an artifact needs a location (where the work product actually is)" if location.empty?

        status = status.to_s.strip.downcase
        unless ARTIFACT_STATUS.include?(status)
          raise Error, "unknown artifact status #{status.inspect}; use #{ARTIFACT_STATUS.join('/')}"
        end

        task_id = blank_to_nil(task_id)
        artifact = {
          "id" => new_id("a"),
          "type" => type,
          "title" => title,
          "project" => blank_to_nil(project),
          "task_id" => task_id,
          "created_by" => blank_to_nil(created_by) || "agent",
          "location" => location,
          "version" => (version || 1).to_i,
          "status" => status,
          "created" => now.utc.iso8601,
          "updated" => now.utc.iso8601
        }
        with_lock do
          if task_id && !tasks.any? { |t| t["id"] == task_id }
            raise Error, "no task #{task_id} to link the artifact to"
          end

          list = artifacts
          list << artifact
          save_artifacts(list)
          emit("kind" => "artifact.registered", "artifact_id" => artifact["id"],
               "task_id" => task_id, "title" => title, "location" => location)
        end
        artifact
      end

      # ---- approvals --------------------------------------------------------

      def approvals = read_json(APPROVALS, "approvals")
      def save_approvals(list) = write_json(APPROVALS, "approvals", list)
      def find_approval(id) = approvals.find { |a| a["id"] == id.to_s }
      def pending_approvals = approvals.select { |a| a["status"] == "pending" }

      # Ask for a human decision. The task moves to NEEDS_APPROVAL, so the view shows it
      # where it belongs instead of pretending work is still happening. What a decision then
      # *means* for the rest of the harness is stage B's policy; here it is one record and
      # one state, which is all stage A owns.
      def request_approval(task_id:, action:, note: nil, now: Time.now)
        action = action.to_s.strip
        raise Error, "an approval needs an action (what the human is approving)" if action.empty?

        task_id = task_id.to_s.strip
        raise Error, "an approval needs a task_id" if task_id.empty?

        approval = {
          "id" => new_id("ap"),
          "task_id" => task_id,
          "action" => action,
          "status" => "pending",
          "requested" => now.utc.iso8601,
          "decided" => nil,
          "decided_by" => nil,
          "note" => blank_to_nil(note)
        }
        with_lock do
          list = tasks
          task = list.find { |t| t["id"] == task_id } or raise Error, "no task #{task_id}"
          unless task["state"] == "NEEDS_APPROVAL"
            from = task["state"]
            unless transition_allowed?(from, "NEEDS_APPROVAL")
              raise Error, "cannot ask for approval on task #{task_id} while it is #{from}"
            end

            task["state"] = "NEEDS_APPROVAL"
            task["note"] = "approval requested: #{action}"
            task["updated"] = now.utc.iso8601
            save_tasks(list)
            emit("kind" => "task.state", "task_id" => task_id, "from" => from, "to" => "NEEDS_APPROVAL",
                 "note" => "approval requested: #{action}")
          end
          alist = approvals
          alist << approval
          save_approvals(alist)
          emit("kind" => "approval.requested", "approval_id" => approval["id"], "task_id" => task_id,
               "action" => action)
        end
        approval
      end

      def decide_approval(id, decision, by: nil, note: nil, now: Time.now)
        decision = decision.to_s.strip.downcase
        unless APPROVAL_DECISIONS.include?(decision)
          raise Error, "a decision is granted or denied (got #{decision.inspect})"
        end

        result = nil
        with_lock do
          alist = approvals
          approval = alist.find { |a| a["id"] == id.to_s } or raise Error, "no approval #{id}"
          unless approval["status"] == "pending"
            raise Error, "approval #{id} is already #{approval['status']}"
          end

          approval["status"] = decision
          approval["decided"] = now.utc.iso8601
          approval["decided_by"] = blank_to_nil(by) || "human"
          approval["note"] = blank_to_nil(note) if blank_to_nil(note)
          save_approvals(alist)

          # Move the task to match, when the move is legal: a granted approval hands the work
          # back to WORKING, a denied one parks it BLOCKED. If the task already moved on
          # (someone set it by hand), the decision is still recorded and the state is left be.
          target = decision == "granted" ? "WORKING" : "BLOCKED"
          tlist = tasks
          task = tlist.find { |t| t["id"] == approval["task_id"] }
          if task && transition_allowed?(task["state"], target)
            from = task["state"]
            task["state"] = target
            task["note"] = "approval #{decision}"
            task["updated"] = now.utc.iso8601
            save_tasks(tlist)
            emit("kind" => "task.state", "task_id" => task["id"], "from" => from, "to" => target,
                 "note" => "approval #{decision}")
          end
          emit("kind" => "approval.#{decision}", "approval_id" => approval["id"],
               "task_id" => approval["task_id"], "by" => approval["decided_by"])
          result = approval
        end
        result
      end

      # A granted approval authorises its action ONCE. This is the only place that
      # consumes one, and it does so under the same store lock as the read, so two
      # identical calls at the same instant cannot both ride one grant -- the second finds
      # nothing and must ask again. The consumption is a line in the log, like every move.
      def take_grant(action, note: nil, now: Time.now)
        action = action.to_s.strip
        result = nil
        with_lock do
          list = approvals
          approval = list.find do |a|
            a["status"] == "granted" && a["consumed"].nil? && a["action"] == action
          end
          next unless approval

          approval["consumed"] = now.utc.iso8601
          approval["note"] = blank_to_nil(note) || approval["note"]
          save_approvals(list)
          emit("kind" => "approval.consumed", "approval_id" => approval["id"],
               "task_id" => approval["task_id"], "action" => action)
          result = approval
        end
        result
      end

      # Append one event to the log, under the store lock, for callers outside this
      # module. The policy layer records every decision here: the event log is the audit
      # trail for who allowed what, and it is the reason this is not private.
      def record(event)
        with_lock { emit(event) }
        event
      end

      # ---- responsibilities -------------------------------------------------
      #
      # A responsibility is a standing commitment, not one piece of work: an objective
      # that stays true, the triggers that start work toward it, the skill that runs, and
      # the autonomy and reporting policy for it. The record here is the durable half;
      # lib/responsibility.rb validates the trigger shapes and matches events to it.
      # A responsibility never "runs" -- each time a trigger fires, one task is created
      # under it (responsibility_id), which is the unit of work a person or the model sees.

      def responsibilities = read_json(RESPONSIBILITIES, "responsibilities")
      def save_responsibilities(list) = write_json(RESPONSIBILITIES, "responsibilities", list)
      def find_responsibility(id) = responsibilities.find { |r| r["id"] == id.to_s }

      def add_responsibility(record, now: Time.now)
        objective = record["objective"].to_s.strip
        raise Error, "a responsibility needs an objective (what it is for)" if objective.empty?

        resp = {
          "id" => new_id("r"),
          "objective" => objective,
          "owner" => blank_to_nil(record["owner"]),
          "project" => blank_to_nil(record["project"]),
          "skill" => blank_to_nil(record["skill"]),
          "autonomy" => blank_to_nil(record["autonomy"]) || "ask",
          "reporting" => blank_to_nil(record["reporting"]) || "on_completion",
          "enabled" => record["enabled"] == false ? false : true,
          "triggers" => Array(record["triggers"]),
          "created" => now.utc.iso8601,
          "updated" => now.utc.iso8601
        }
        with_lock do
          list = responsibilities
          list << resp
          save_responsibilities(list)
          emit("kind" => "responsibility.created", "responsibility_id" => resp["id"],
               "objective" => objective, "project" => resp["project"])
        end
        resp
      end

      def set_responsibility_enabled(id, on, now: Time.now)
        with_lock do
          list = responsibilities
          resp = list.find { |r| r["id"] == id.to_s } or raise Error, "no responsibility #{id}"
          resp["enabled"] = on ? true : false
          resp["updated"] = now.utc.iso8601
          save_responsibilities(list)
          emit("kind" => "responsibility.#{on ? 'enabled' : 'disabled'}",
               "responsibility_id" => resp["id"])
          resp
        end
      end

      def remove_responsibility(id)
        with_lock do
          list = responsibilities
          before = list.size
          list.reject! { |r| r["id"] == id.to_s }
          save_responsibilities(list)
          before != list.size
        end
      end

      # ---- the event inbox --------------------------------------------------
      #
      # Pending unified events, the ledger of the ones already handled, and how far the
      # event log has been scanned for internal transitions. Same read-modify-write under
      # the one lock as every other store here. The ledger only stops a replayed event
      # from being queued again; the binding "one event, one task" guarantee is the task's
      # event_key (add_task_once), which holds however long ago the event was first seen.

      def inbox_store
        return { "events" => [], "handled" => [], "scan" => {} } unless File.exist?(INBOX)

        data = begin
          JSON.parse(File.read(INBOX))
        rescue JSON::ParserError => e
          raise Error, "#{INBOX} is not valid JSON (#{e.message}); fix or delete it"
        end
        unless data.is_a?(Hash) && data["events"].is_a?(Array) && data["handled"].is_a?(Array)
          raise Error, "#{INBOX} is not an event inbox (expected {\"events\": [...], \"handled\": [...]}); " \
                       "fix or delete it"
        end
        data["scan"] = {} unless data["scan"].is_a?(Hash)
        data
      end

      def save_inbox(data)
        FileUtils.mkdir_p(File.dirname(INBOX))
        tmp = "#{INBOX}.#{Process.pid}.tmp"
        File.open(tmp, "w") do |f|
          f.write(JSON.pretty_generate(data.merge("updated" => Time.now.utc.iso8601)) + "\n")
          f.fsync
        end
        File.rename(tmp, INBOX)
      end

      def pending_events = inbox_store["events"]

      # ---- the notification store -------------------------------------------
      #
      # The outbound queue, the dedupe ledger and the scan watermark, in one file, the
      # same shape and the same one lock as everything above. lib/notify.rb is the logic;
      # this is only the store, so a failed send has somewhere durable to wait.
      def notifications_store
        empty = { "queue" => [], "seen" => {}, "digest" => [], "scan" => 0, "undeliverable" => 0 }
        return empty unless File.exist?(NOTIFICATIONS)

        data = begin
          JSON.parse(File.read(NOTIFICATIONS))
        rescue JSON::ParserError => e
          raise Error, "#{NOTIFICATIONS} is not valid JSON (#{e.message}); fix or delete it"
        end
        unless data.is_a?(Hash) && data["queue"].is_a?(Array) && data["seen"].is_a?(Hash)
          raise Error, "#{NOTIFICATIONS} is not a notification store (expected " \
                       "{\"queue\": [...], \"seen\": {...}}); fix or delete it"
        end
        data["digest"] = [] unless data["digest"].is_a?(Array)
        data["scan"] = 0 unless data["scan"].is_a?(Integer)
        data
      end

      def save_notifications(data) = write_object(NOTIFICATIONS, data)

      # The heartbeat's last pass, so `claw status` can say when it last ran and what it
      # did without running one. A record about the harness, not about the work.
      def heartbeat_state
        return {} unless File.exist?(HEARTBEAT_STATE)

        data = begin
          JSON.parse(File.read(HEARTBEAT_STATE))
        rescue JSON::ParserError
          {}
        end
        data.is_a?(Hash) ? data : {}
      end

      def save_heartbeat_state(data) = write_object(HEARTBEAT_STATE, data)

      # A JSON object store, written through a temp file and a rename with an fsync first,
      # the way every list store above is.
      def write_object(path, object)
        FileUtils.mkdir_p(File.dirname(path))
        tmp = "#{path}.#{Process.pid}.tmp"
        File.open(tmp, "w") do |f|
          f.write(JSON.pretty_generate(object.merge("updated" => Time.now.utc.iso8601)) + "\n")
          f.fsync
        end
        File.rename(tmp, path)
      end

      # The raw lines of the event log, for the heartbeat's scan of internal transitions.
      # Raw, not parsed, because the scan remembers its position by line number and a log
      # line a person hand-edited to nonsense must not shift every later line's identity.
      def event_log_raw
        return [] unless File.exist?(EVENTS)

        File.readlines(EVENTS)
      end

      # ---- reading the log --------------------------------------------------

      # Every event, oldest first, optionally for one task. Malformed lines are skipped
      # rather than raising: a hand-edited log should not blind the whole view.
      def events(task_id: nil, limit: nil)
        parsed = event_log_raw.filter_map do |line|
          begin
            JSON.parse(line)
          rescue JSON::ParserError
            nil
          end
        end
        parsed.select! { |e| e["task_id"] == task_id.to_s } if task_id
        limit ? parsed.last(limit.to_i) : parsed
      end

      # One task's history, as lines a person can read. This is the point of the log: the
      # state of a task is the store, but the *story* of it is reconstructable from here.
      def history(task_id, limit: 20)
        events(task_id: task_id, limit: limit).map do |e|
          parts = [e["ts"].to_s[0, 19].tr("T", " "), e["kind"]]
          if e["from"] && e["to"]
            parts << "#{e['from']}->#{e['to']}"
          elsif e["to"] || e["state"]
            parts << (e["to"] || e["state"])
          end
          parts << e["note"] if e["note"]
          parts.join("  ")
        end
      end

      # ---- age, in a person's words -----------------------------------------

      def age_seconds(thing, now: Time.now)
        stamp = thing.is_a?(Hash) ? thing["updated"] : thing
        [now - Time.parse(stamp.to_s), 0].max.round
      rescue StandardError
        0
      end

      def human_seconds(secs)
        secs = secs.to_i
        return "#{secs}s" if secs < 60
        return "#{secs / 60}m" if secs < 3600
        return "#{secs / 3600}h#{(secs % 3600) / 60}m" if secs < 86_400

        "#{secs / 86_400}d#{(secs % 86_400) / 3600}h"
      end

      def age(thing, now: Time.now) = human_seconds(age_seconds(thing, now: now))

      # ---- the view ---------------------------------------------------------

      # Plain text, in the order that helps a person reading it: anything stuck or waiting on
      # them first, then open work oldest-first, then what finished, then the artifacts
      # grouped by the task they came from. This is the honest substitute for a dashboard.
      def render(now: Time.now)
        ts = tasks
        arts = artifacts
        apps = approvals
        pending = apps.select { |a| a["status"] == "pending" }

        out = +"RubyClaw work — #{ts.size} task(s), #{arts.size} artifact(s), " \
               "#{pending.size} waiting on you\n"
        return out << "\nnothing yet — add one with `claw work add \"<title>\"`, or the `work` tool.\n" \
          if ts.empty? && arts.empty? && apps.empty?

        out << attention_block(ts, pending, now)
        out << open_block(ts, now)
        out << done_block(ts, now)
        out << artifacts_block(ts, arts, now)
        out << approvals_block(apps, now)
        out
      end

      def attention_block(ts, pending, now)
        rows = ts.select { |t| ATTENTION.include?(t["state"]) }.sort_by { |t| -age_seconds(t, now: now) }
        return "" if rows.empty?

        out = +"\nATTENTION\n"
        rows.each do |t|
          out << task_line(t, now: now)
          reason = t["note"]
          if reason.nil? && t["state"] == "NEEDS_APPROVAL"
            reason = pending.find { |a| a["task_id"] == t["id"] }&.dig("action")
          end
          out << "      #{reason}\n" if reason
        end
        out
      end

      def open_block(ts, now)
        rows = ts.reject { |t| ATTENTION.include?(t["state"]) || %w[DONE FAILED].include?(t["state"]) }
        return "" if rows.empty?

        out = +"\nOPEN\n"
        rows.sort_by { |t| -age_seconds(t, now: now) }.each { |t| out << task_line(t, now: now) }
        out
      end

      def done_block(ts, now)
        rows = ts.select { |t| %w[DONE FAILED].include?(t["state"]) }.sort_by { |t| -age_seconds(t, now: now) }
        return "" if rows.empty?

        out = +"\nFINISHED (newest first)\n"
        rows.first(10).each do |t|
          out << task_line(t, now: now)
          # Why it failed, where a person is already looking. A state on its own says a
          # task stopped, not what stopped it.
          out << "      #{t['note']}\n" if t["state"] == "FAILED" && t["note"]
        end
        out << "      …and #{rows.size - 10} more\n" if rows.size > 10
        out
      end

      def artifacts_block(ts, arts, now)
        return "" if arts.empty?

        grouped = arts.group_by { |a| a["task_id"] }
        order = (ts.map { |t| t["id"] } & grouped.keys) + (grouped.keys - ts.map { |t| t["id"] })
        out = +"\nARTIFACTS\n"
        order.each do |task_id|
          task = ts.find { |t| t["id"] == task_id }
          out << "  #{task ? "#{task['id']}  #{task['title']}" : '(no task)'}\n"
          grouped[task_id].each { |a| out << "    #{artifact_line(a, now: now)}\n" }
        end
        out
      end

      def approvals_block(apps, now)
        return "" if apps.empty?

        out = +"\nAPPROVALS\n"
        apps.sort_by { |a| a["status"] == "pending" ? 0 : 1 }.each do |a|
          pending = a["status"] == "pending"
          waiting = pending ? "  (waiting #{human_seconds(age_seconds(a['requested'], now: now))})" : ""
          out << format("  %-8s %-12s %-12s %s%s\n", a["status"], a["id"], a["task_id"], a["action"], waiting)
          # The exact command, where the person reading this needs it: the whole point of
          # the view is that nothing has to be looked up elsewhere.
          out << "           grant: claw work decide #{a['id']} granted   deny: claw work decide #{a['id']} denied\n" if pending
        end
        out
      end

      def task_line(task, now: Time.now)
        format("  %-15s %-14s %-6s %s%s\n", task["state"], task["id"], age(task, now: now), task["title"],
               deadline_note(task, now: now))
      end

      # A deadline is the thing the heartbeat acts on, so the view shows it -- and shows
      # loudly when it has passed, which is exactly when a person is being waited for.
      def deadline_note(task, now: Time.now)
        stamp = task["deadline"].to_s
        return "" if stamp.strip.empty?

        past = begin
          Time.parse(stamp) <= now
        rescue StandardError
          false
        end
        label = past ? "PAST DEADLINE" : "due"
        "  [#{label} #{stamp[0, 16].tr('T', ' ')}]"
      end

      def artifact_line(artifact, now: Time.now)
        format("%-12s [%s] %s  %s v%d  %s  (%s)", artifact["id"], artifact["type"], artifact["title"],
               artifact["status"], artifact["version"].to_i, artifact["location"],
               age(artifact, now: now))
      end

      def blank_to_nil(value) = value.to_s.strip.empty? ? nil : value.to_s.strip
    end
  end
end
