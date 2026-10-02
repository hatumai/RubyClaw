# instance/ — what this harness grew for itself

Everything in here belongs to *this* instance, not to the project it came from.

    instance/tools/    Ruby tools it wrote and kept
    instance/skills/   procedures it worked out and would hate to rediscover

`claw update` never touches this directory. Not because it compares contents and decides to leave it
alone, but because the update refuses these paths outright before it looks at anything — so there is
nothing to detect and nothing that can go wrong with the detection. Anything that writes growth
(`extend kind: "tool"` or `"skill"`, the sandbox, your own hands) writes here.

It is still part of the git repository, so growth is committed and `claw rollback` reaches it. What
is guaranteed is narrower and stronger than that: **upstream has no path into this directory that an
update can follow.**
