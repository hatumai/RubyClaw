# The model's handle on standing commitments (lib/responsibility.rb).
#
# A task is one piece of work; a responsibility is the thing that keeps asking for work.
# Thin on purpose -- the store and the matching live in lib/, this is a set of verbs.
# Each trigger that fires creates exactly one durable task under the responsibility (see
# lib/event.rb); the heartbeat (lib/heartbeat.rb) is what drains the events, and `claw
# heartbeat` runs one pass by hand.
RubyClaw.tool(
  "responsibility",
  description: "Standing commitments that outlive a prompt: an objective, an owner, a " \
               "project, a skill/workflow, an autonomy level, a reporting policy and the " \
               "triggers that start work toward it. The store is data/responsibilities.json. " \
               "Each trigger that fires creates exactly one durable task under the " \
               "responsibility (never a second for the same event); the heartbeat turns " \
               "pending events into tasks and resumes/retries work. Actions: list | " \
               "add(objective, triggers) | show(id) | enable(id) | disable(id) | remove(id). " \
               "A trigger is 'timer every 15m' | 'file.changed /abs/path' | 'work.state DONE' | " \
               "'job.finished <name>' | 'webhook <source>' | 'scout <search query>'. A scout " \
               "trigger polls a read-only keyless web search (every 6h by default, so it " \
               "cannot hammer anyone) and turns each page it has not seen before into one " \
               "task; the finding's title and URL are on the task's detail. Timers, file " \
               "changes, scout queries, internal transitions and job finishes exist here; " \
               "email/calendar/GitHub feeds do not.",
  params: {
    "action" => { type: "string", description: "list|add|show|enable|disable|remove" },
    "id" => { type: "string", required: false, description: "responsibility id (r-...)" },
    "objective" => { type: "string", required: false,
                     description: "add: what stays true, e.g. 'keep the deploy notes current'" },
    "triggers" => { type: "string", required: false,
                    description: "add: one or more triggers, separated by newlines or ';'" },
    "owner" => { type: "string", required: false },
    "project" => { type: "string", required: false },
    "skill" => { type: "string", required: false, description: "the skill/workflow to run for it" },
    "autonomy" => { type: "string", required: false, description: "auto|ask (default ask)" },
    "reporting" => { type: "string", required: false,
                     description: "on_change|on_completion|never (default on_completion)" }
  }
) do |a|
  r = RubyClaw::Responsibility
  w = RubyClaw::Work
  case a["action"].to_s.downcase
  when "list", "view"
    r.render
  when "add", "create"
    triggers = a["triggers"].to_s.split(/[\n;]+/).map(&:strip).reject(&:empty?)
    resp = r.add(objective: a["objective"], owner: a["owner"], project: a["project"],
                 skill: a["skill"], autonomy: a["autonomy"] || "ask",
                 reporting: a["reporting"] || "on_completion", triggers: triggers)
    "added #{resp['id']}: #{resp['objective']} — triggers: " \
      "#{resp['triggers'].map { |t| r.describe_trigger(t) }.join('; ')}"
  when "show"
    resp = r.find(a["id"]) or raise RubyClaw::Error, "no responsibility #{a['id']}"
    lines = ["#{resp['id']} #{resp['objective']} (#{resp['enabled'] == false ? 'paused' : 'active'})",
             "  owner=#{resp['owner']} project=#{resp['project']} skill=#{resp['skill']} " \
             "autonomy=#{resp['autonomy']} reporting=#{resp['reporting']}"]
    (resp["triggers"] || []).each { |t| lines << "  trigger #{t['id']} #{r.describe_trigger(t)}" }
    w.tasks_for_responsibility(resp["id"]).each { |t| lines << "  task #{t['id']} #{t['state']} #{t['title']}" }
    lines.join("\n")
  when "enable", "disable"
    resp = w.set_responsibility_enabled(a["id"], a["action"].to_s.downcase == "enable")
    "#{resp['enabled'] ? 'enabled' : 'disabled'} #{resp['id']}"
  when "remove", "delete"
    w.remove_responsibility(a["id"]) ? "removed #{a['id']}" : "no responsibility #{a['id']}"
  else
    "unknown responsibility action #{a['action'].inspect}: use list|add|show|enable|disable|remove"
  end
end
