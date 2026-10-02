# The model's handle on the work store (lib/work.rb).
#
# Thin on purpose: the store is the substance, this is a set of verbs over it. Tasks live
# outside the conversation, so the model can say "this is queued" or "this is waiting on a
# person" and be held to it in the next session, on another surface, after a restart.
RubyClaw.tool(
  "work",
  description: "Durable operational state, outside the chat: tasks with a real state, an " \
               "append-only event log, artifacts tied to the task that produced them, and " \
               "approvals waiting on a human. The store is data/work.json (+ events.jsonl, " \
               "artifacts.json, approvals.json), readable and editable by hand. States: " \
               "QUEUED THINKING WORKING WAITING BLOCKED NEEDS_APPROVAL DONE FAILED; illegal " \
               "moves are refused (a DONE task is reopened explicitly, not silently). " \
               "Actions: add(title) | update(id, state?, title?/detail?/note?) | state(id, " \
               "state, note) | reopen(id, note) | list | show(id) | artifact(type, title, " \
               "location, task_id?) | artifacts | request(id, what) | decide(approval_id, " \
               "decision, by?) | approvals. Prefer this over saying in chat that something is " \
               "done: register the artifact, then move the task to DONE.",
  params: {
    "action" => { type: "string",
                  description: "add|update|state|reopen|list|show|artifact|artifacts|request|decide|approvals" },
    "id" => { type: "string", required: false, description: "task id (t-...), or approval id (ap-...) for decide" },
    "title" => { type: "string", required: false },
    "state" => { type: "string", required: false,
                 description: "QUEUED THINKING WORKING WAITING BLOCKED NEEDS_APPROVAL DONE FAILED" },
    "note" => { type: "string", required: false, description: "why, in one line; kept on the task and in the log" },
    "detail" => { type: "string", required: false },
    "project" => { type: "string", required: false },
    "owner" => { type: "string", required: false },
    "type" => { type: "string", required: false, description: "artifact type: report|file|patch|url|..." },
    "location" => { type: "string", required: false, description: "where the artifact actually is (path or URL)" },
    "task_id" => { type: "string", required: false, description: "the task the artifact came from" },
    "version" => { type: "integer", required: false },
    "status" => { type: "string", required: false, description: "artifact status: draft|current|superseded" },
    "what" => { type: "string", required: false, description: "request: the action a human must approve" },
    "decision" => { type: "string", required: false, description: "decide: granted|denied" },
    "by" => { type: "string", required: false, description: "decide: who decided" }
  }
) do |a|
  w = RubyClaw::Work
  case a["action"].to_s.downcase
  when "add", "create"
    t = w.add_task(title: a["title"], project: a["project"], detail: a["detail"], owner: a["owner"])
    "queued #{t['id']}: #{t['title']}"
  when "state"
    t = w.set_state(a["id"], a["state"], note: a["note"])
    "#{t['id']} is now #{t['state']}"
  when "reopen"
    t = w.reopen(a["id"], note: a["note"])
    "reopened #{t['id']} -> QUEUED"
  when "update"
    out = []
    if a["state"]
      t = w.set_state(a["id"], a["state"], note: a["note"])
      out << "#{t['id']} is now #{t['state']}"
    end
    if %w[title project detail owner].any? { |k| a[k] }
      t = w.update_task(a["id"], title: a["title"], project: a["project"], detail: a["detail"], owner: a["owner"])
      out << "updated #{t['id']}"
    end
    raise RubyClaw::Error, "update needs a state or a field to change" if out.empty?

    out.join("; ")
  when "list", "view"
    w.render
  when "show"
    t = w.find_task(a["id"]) or raise RubyClaw::Error, "no task #{a['id']}"
    lines = [w.task_line(t).rstrip]
    art = w.artifacts_for(t["id"])
    lines << "artifacts: #{art.map { |x| "#{x['id']} #{x['title']} (#{x['location']})" }.join(', ')}" if art.any?
    lines.concat(w.history(t["id"]).map { |l| "  #{l}" })
    lines.join("\n")
  when "artifact", "register"
    art = w.register_artifact(type: a["type"], title: a["title"], location: a["location"],
                              task_id: a["task_id"], project: a["project"], version: a["version"],
                              status: a["status"] || "draft", created_by: "agent")
    "registered #{art['id']}: #{art['type']} #{art['title']} at #{art['location']}" \
      "#{art['task_id'] ? " (task #{art['task_id']})" : ''}"
  when "artifacts"
    list = a["task_id"] ? w.artifacts_for(a["task_id"]) : w.artifacts
    next "no artifacts yet" if list.empty?

    list.map { |x| "#{x['id']} [#{x['type']}] #{x['title']} — #{x['status']} v#{x['version']} — " \
                   "#{x['location']}#{x['task_id'] ? " (task #{x['task_id']})" : ''}" }.join("\n")
  when "request", "approve_request"
    ap = w.request_approval(task_id: a["id"], action: a["what"], note: a["note"])
    "waiting on a human: #{ap['id']} — #{ap['action']} (task #{ap['task_id']})"
  when "decide"
    ap = w.decide_approval(a["id"], a["decision"], by: a["by"], note: a["note"])
    "#{ap['id']} #{ap['status']} by #{ap['decided_by']}; task #{ap['task_id']} is now " \
      "#{w.find_task(ap['task_id'])&.fetch('state', '?')}"
  when "approvals"
    apps = w.approvals
    next "no approvals yet" if apps.empty?

    apps.map { |x| "#{x['status']} #{x['id']} task #{x['task_id']}: #{x['action']}" }.join("\n")
  else
    "unknown work action #{a['action'].inspect}: use add|update|state|reopen|list|show|" \
      "artifact|artifacts|request|decide|approvals"
  end
end
