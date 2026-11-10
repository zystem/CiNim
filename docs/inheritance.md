# Organisations, groups and what they inherit

The organisation is the root of a tree of groups; a project is a leaf with a repository (D-68). A setting can be held at any level, and what a project gets is made of the levels above it. There is no
one rule for every setting, and the same word, "inherit", means different things for a variable and for a protected branch, so the settings are in four classes, and each class has **one** rule.
The rules are the ones that GitLab, GitHub, Jenkins, TeamCity, Argo CD and the cloud policies of Google and AWS converged on (see the end), made predictable by two habits: an empty value
**inherits** (a level can always go back to what is above), and the answer always says **where a value comes from**.

| Class | The rule going down | Settings of CiNim |
|---|---|---|
| **Values** | the **nearest** level that sets it wins; empty inherits | variables, secrets (the nearest holder of a name), `default_ref`, `status_target`, cache quota and retention (0 inherits), the longest step (`max_step_timeout_seconds`, `limits.configure`: the shard says 24 h, at most a week at any level) |
| **Guardrails** | a level below can only **tighten**, never relax | `protected_refs` (the union: a group can add a protected branch and cannot take one away), `required_approvals` (the most any level asks for) |
| **Grants** | **added** going down, nothing by default; who may grant is a permission | roles (`access.write`), `allowed_profiles` (`profile.grant`), `allowed_callers` (`caller.allow`) |
| **Objects of the organisation** that groups choose from | the organisation is the **ceiling**; a group can only **narrow** the set, never widen it; empty inherits | registries (`allowed_registries`, `registry.grant`: the root has all of them, D-114); deploy profiles are privileged (a token) and so are a **grant**: none until a group lists them (D-115) |
| **Not inherited** | belongs to one place | a trigger (one project; its name is unique in the project), a run, a webhook (set on a node it covers that node and everything under it, D-111: this is its scope, not an inheritance) |

## What an answer says

`GET /api/v1/organizations/{slug}/projects/{path}/settings` (and the same under `groups`) gives, for each inherited setting, the group's **own** value (what a PUT wrote; `[]` or `null` is "inherits"), the **effective** one
(`effective_protected_refs`, `effective_allowed_callers`, `effective_required_approvals`, `effective_status`, `effective_allowed_registries`, `default_ref`), and `sources`: for a list the groups that add to it,
for a value the group that sets it. The organisation sets none, so a project whose groups say nothing has an empty list, one approval, no target, the branch `main` and every registry.
A PUT writes the group's own value; an empty list takes it away, and the group inherits again. These settings may be set on a group as well as on a project.

## Why these rules

* A value that is a **default** is the nearest one because that is what people expect of a variable: the more specific place says what it means (GitLab and TeamCity variables and parameters, Jenkins folder
  properties, the booleans of Google's organisation policy).
* A **guardrail** that a group below could relax is no guardrail: a project could un-protect the branch that its group protects. So it only tightens (AWS service control policies cap what is possible below;
  in Google's list policies a deny wins when the levels are merged; GitHub's rulesets of the organisation and of a repository are aggregated). Google's `inheritFromParent: false`, which replaces what the parent says,
  is left out on purpose: a level that can cancel the one above is what makes a policy tree unpredictable.
* A **grant** starts from nothing and grows downward; the one who may add is named by a permission on that level (Jenkins credentials of a folder are seen below it and not beside it).
* An **object of the organisation** exists once, and a group says which of them it uses: GitHub's organisation secrets with "selected repositories", Argo CD's project with lists of repositories and destinations that
  an application may use. The organisation is the ceiling because the object is its own; a group that could list what the organisation does not hold would only hold a name.
* A person who asks "why" must be told: GitLab shows the source of an inherited member; GitLab's open complaint is that a subgroup that overrode a setting **cannot go back**, so here an empty value always goes back.

## Sources

[GitLab: subgroups and inherited settings](https://docs.gitlab.com/user/group/subgroups/), the issue about [re-inheriting an overridden setting](https://gitlab.com/gitlab-org/gitlab/-/issues/349226);
[GitHub: organisation rulesets](https://docs.github.com/en/enterprise-server@3.20/organizations/managing-organization-settings/creating-rulesets-for-repositories-in-your-organization) and
[organisation secrets by repository access](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets);
[Google Cloud organisation policy: hierarchy evaluation](https://docs.cloud.google.com/organization-policy/hierarchy-evaluation); [Argo CD projects](https://argo-cd.readthedocs.io/en/release-3.1/user-guide/projects/);
[TeamCity subprojects](https://jetbrains.com/help/teamcity/8.0/subproject.html); [Buildkite permissions](https://buildkite.com/docs/pipelines/permissions).
