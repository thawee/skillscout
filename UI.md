# Skillscout Mod UI reference

This document describes the current macOS interface and the six-perspective target presentation. The target sections below specify planned behavior. The remaining sections describe the implemented interface. [DESIGN.md](DESIGN.md) explains the rationale. [README.md](README.md) describes installation and end-user workflows.

## Target navigation by perspective

The target sidebar has six main perspectives.

```text
Dashboard
Discovery
Storage
    Library
    Global
    Projects
AI tools
Skillsets
Ideas
```

Dashboard contains usage views and review links. Discovery retains Git repositories and Local folders. Storage groups Library, Global, and registered projects. AI tools starts with an agent, then shows a Global or project scope control. Skillsets selects a collection. Ideas contains Suggestions and Similar skills.

Chat activity routes into the Dashboard perspective with the relevant usage filter. Plugin inspection routes into the selected AI tool. The current sidebar has not yet been reorganized into this grouping.

## Target skill presentation by perspective

Every skill has a name, description, stable identity, and source relationships. Each perspective adds its own leading facts, status badges, and actions. The badges below are a vocabulary contract. A badge appears only when the underlying state supports it.

| Perspective | Leading skill information | Contextual status badges | Primary and supporting actions |
| --- | --- | --- | --- |
| Dashboard | Chats, last recorded use, selected period and project, and the specific review finding. | No recorded use, Differing copies, Source unavailable, or Review needed. | Open skill, Review copies, Inspect contents, or Compare skills. Removal requires navigation to a management scope. |
| Discovery | Origin, branch or pinned version, description, preview contents, scripts, and import state for this source. | Preview, In Library, Update available, Pinned, Tag moved, or Review needed. | Add to Library, Inspect contents, Review update, or Choose version. Agent availability refers to this source where known, not merely another skill with the same name. |
| Storage: Library | Source kind, repository or draft identity, stored location, editability, and skillset membership. | Draft, Repository, Shared source, Library only, Locally edited, or Source unavailable. | Add skills to a destination, Add to skillset, Edit or Rename when allowed, or inspect the source. Repository removal identifies the whole repository and affected links. |
| Storage: Global | Physical entries, supplying source, every affected reader, existing-copy differences, and protection. | Available, Shared entry, Personal, Plugin, Built-in, or Differing copies. | Inspect entry, or Add to a selected agent when it lacks the skill. Supporting Move to Library when allowed, Reveal in Finder, and reviewed Remove from agent. |
| Storage: Projects | Project path, target group, local copies, inherited copies, ownership, and assignment snapshot. | Project, Inherited from Global, Managed copy, Unmanaged copy, Modified copy, Conflict, Separate update available, Source removed, or Project unavailable. | Inspect project copy, or Manage in Global for inherited installations. Supporting Add to project, Review project update, and Remove from project. |
| AI tools | Selected agent and workspace, supplying folders, source, reader relationships, and scoped recorded use. | Available to this agent, Inherited from Global, Shared entry, Plugin, Built-in, Differing copies, or No recorded use. | Add to this agent, inspect its supplying copy, or review scoped removal. Shared-entry removal previews every affected reader. Plugin entries link to read-only plugin details. |
| Skillsets | Selected collection, membership, chosen source, assignment destinations, applied snapshot, and unapplied changes. | Member, Missing source, Assigned to a named destination, or Changes pending for a named destination. | Open or Choose source; Preview application in the collection header. Membership removal and destination Unassign are separate reviewed scopes. |
| Ideas | Supporting requests, frequency in loaded history, draft state, saved source, and availability of the saved skill. | Suggested, Draft, Saved to Library, or Saved source missing. Similar pairs carry no status badges. | Draft with AI, Edit draft, Save to Library, Open saved skill, Add saved skill to a destination, or Add to skillset. A saved draft is not automatically installed. |

Storage has three rows in this table because each location has different ownership and removal rules. It remains one of the six perspectives. The detail sections below are authoritative where this summary is shorter.

Agent badges follow the [single badge rule](DESIGN.md#every-applicable-agent-stays-visible). Settings is the authority for enabled tools throughout normal displays and choices. Agent badges describe readers. Assignment badges describe assignments. Usage badges always carry a period and applicable history scope in nearby text.

## Target list panel and skill details

This contract defines proposed information placement. It does not claim the current views already implement these layouts.

### Shared frame

The list header shows perspective, selected scope, search, filters, sort, and filtered item count. Put a shared project, agent, period, or collection here instead of repeating it in every row. Dashboard is a report with selectable ranked or attention items rather than a required three-column list.

Each skill row shows, in order: **name**, a description of at most two lines, one compact perspective fact line, relevant status labels, and the reader badge group. A finding needing attention appears directly after the name. Show a short source label when needed to distinguish copies; full paths, receipts, snapshots, scripts, and history belong in details. Selecting a row opens details and performs no installation or removal.

The detail header keeps name, description, source identity, and active scope visible. If a grouped skill has several sources, select the source or entry before showing its contents or offering source-specific actions. An urgent finding can follow the header; evidence and perspective facts then precede the primary action. Contents, locations, history, and cross-perspective links follow. The primary action is useful for the current state; removal remains secondary and reviewed.

### Dashboard

- **List or report item:** skill name and description, recorded chat count, last recorded use, and an attention cue such as Differing copies or Review needed.
- **Header:** period, project, agent filter, and included history. Reader badges, when shown, are labelled **Available to** and kept separate from contributing chat agents.
- **Detail order:** Recorded use, Finding and evidence, Relevant sources or copies, Action, Contents and management links.
- **Detail facts:**
  - Recorded use includes the tool and project breakdown, last date, and history coverage.
  - A finding identifies the actual paths or pair involved. A name-wide tally does not prove which copy ran.
- **Badges:** No recorded use, Differing copies, Source unavailable, Review needed, only where supported.
- **Actions:** primary **Review copies**, **Inspect contents**, or **Compare skills** for the selected finding; otherwise **Open skill in Storage**. No direct uninstall or source removal here.

### Discovery

- **List item:** skill name, preview description, short repository or folder label, relative skill path, import state for this exact source, and a compact content-review cue. An unrelated same-name installation does not mean this source is In Library.
- **Header:** branch or tag and source selection, when shared by all rows.
- **Detail order:** Source and selected version, Import or update state, Preview contents and findings, Action, Known installations and other same-name sources.
- **Detail facts:**
  - Origin address, relative path, installed and incoming commits when known, pin state, and last successful check.
  - Local sources use folder-refresh language.
  - New upstream skills are identified by their source-relative paths.
  - Without a successful check, say **Not checked** or report the failed check. Never imply Up to date.
- **Badges:** Preview, In Library, Update available, Pinned, Tag moved, Review needed.
- **Actions:**
  - Primary **Add source to Library…** for an unimported source, **Review update…** for a checked change, or **Open in Library** otherwise.
  - Addition and update previews name the whole repository or folder being imported or replaced, even when opened from one skill.
  - Supporting **Check for updates**, **Refresh from Folder**, **Choose version**, and **Inspect contents**, depending on source type.
  - Update review shows choices, final contents and impact before Apply.

### Storage: Library

- **List item:** skill name, description, short source label, source kind, edit or access state, and skillset membership count when useful.
- **Readers:** **Available from this source** shows all proven enabled readers. No enabled reader is **Not available to enabled tools**. **Library only** requires no physical agent installations, not merely no enabled reader.
- **Detail order:** Stored source, Edit or access state, Where this source is applied, Skillset memberships, Action, Contents and locations.
- **Detail facts:**
  - Exact stored path, recorded origin and version, and links to this source.
  - Independent and project copies with verified receipt provenance, and their separate update states.
  - Unknown provenance is labelled rather than inferred from a name.
- **Badges:** Draft, Repository, Shared source, Library only, Source unavailable. Locally edited appears only after a baseline comparison.
- **Actions:**
  - Primary **Add to destination…**, or a recovery or review action when blocked.
  - Supporting **Add to skillset**, **Edit SKILL.md…**, **Rename…**, **Reveal in Finder**, and source update actions, when allowed.
  - **Remove source from Library…** names the repository when it removes a whole repository, and previews affected links.

### Storage: Global

- **List item:** skill name, description, short supplying-entry or source label, copy count when multiple entries exist, protection or difference state, and all readers of the displayed entries.
- **Header:** the agent filter. A shared entry is not exclusively owned by the selected agent. Recorded use covers all loaded history for that agent selection, without project or period selectors.
- **Detail order:** Global entries, Supplying source and readers, Differences and protection, Action, Selected contents and scoped recorded use.
- **Detail facts:**
  - Each entry shows its physical path, resolved target, link or copy form, source kind, and every reader.
  - Select an entry to inspect or change it. Never silently use the first same-name copy.
- **Badges:** Available, Shared entry, Personal, Plugin, Built-in, Differing copies.
- **Actions:**
  - Primary **Inspect entry**, or **Add to [agent]…** when the chosen agent lacks the skill.
  - Supporting **Move to Library…**, **Reveal in Finder**, and **Remove entry from [agent]…** when supported.
  - Removal review identifies the physical entry and every affected reader. Other entries can continue supplying availability.
  - Plugin and built-in content stays protected.

### Storage: Projects

- **List item:** skill name, description, Project or Inherited from Global location status, local copy state, and all relevant readers. A skill available locally and globally appears once, with both location labels. Readers are grouped by location when they differ.
- **Header:** project, availability filter, and **Add to project…**.
- **Detail order:** Project-local copies, Inherited Global entries, Ownership and assignments, Action, Contents and project-scoped recorded use.
- **Detail facts:**
  - Full project path, local target groups and paths, receipt ownership, recorded source path, applied assignment snapshot, and verified pending changes.
  - Inherited entries have their own paths, readers, and management link.
  - Recorded use is not attributed to local or inherited copies unless path evidence supports it.
- **Badges:** Project, Inherited from Global, Managed copy, Unmanaged copy, Modified copy, Conflict, Separate update available, Source removed, Project unavailable, each only after the relevant check.
- **Actions:**
  - Primary **Inspect project copy** for local content, or **Manage in Global…** for inherited-only content.
  - Supporting **Review project update…**, **Reveal in Finder**, and **Remove from [project]…**, each specific to its target.
  - Modified or unowned files remain protected. Removing local content does not remove inherited Global entries.

### AI tools

- **List item:** skill name, description, how the selected agent can read it (Project, Global, or both), short supplying-entry label, and scoped recorded use when available. Show all readers of affected shared entries, with the selected agent emphasized and none hidden.
- **Header:** agent, workspace, and period.
- **Detail order:** How [agent] reads this skill, Supplying entries and other readers, Recorded use and history limits, Action, Contents and plugin details.
- **Detail facts:**
  - Exact roots and resolved paths, with project and Global suppliers separated.
  - Multiple supplying copies do not establish precedence unless the agent's verified read rules establish it.
- **Badges:** Available to [agent], Inherited from Global, Shared entry, Plugin, Built-in, Differing copies, No recorded use.
- **Actions:**
  - Primary **Inspect supplying copy** for available content, or **Add to [agent] in [scope]…** in an addition flow.
  - Scoped removal opens an entry review. Inherited project content uses **Manage in Global…**.
  - Plugin details are read-only.
  - Installed or available, assigned, and recorded use stay separate facts.

### Skillsets

- **List item:** member name, description if the source resolves, chosen source label, missing-source cue, and destination-specific assignment or pending state. Reader badges are secondary and labelled **Source available to**; they do not imply assignment.
- **Header:** the selected skillset, its assignment summary, and **Preview application…** with an explicit destination.
- **Detail order:** Membership and chosen source, Assignment destinations, Applied snapshots and pending differences, Action, Source contents.
- **Detail facts:**
  - Membership, Global assignments, project target snapshots, and actual availability stay distinct.
  - When resolution fails, show the expected source path and alternatives.
  - Preferred source is app-wide per skill identity. A change affects later plans across Skillscout, not just this skillset, and does not rewrite existing copies.
- **Badges:** Member, Missing source, Assigned to [destination], Changes pending for [destination].
- **Actions:**
  - Primary **Open source**, or **Choose source…** when the source is missing or ambiguous.
  - Supporting **Remove from [skillset]**, **Add to another skillset**, and **Review unassign from [destination]…** affect their named records.
  - Removing membership does not uninstall skills or rewrite project snapshots.

### Ideas

Suggestions:

- **List item:** idea title, summary, number of supporting requests in loaded history, and draft or save state. Tool badges are labelled **Evidence from**, not Available to. Project evidence can be summarized here and expanded in details.
- **Detail order:** Why suggested, Matched requests, Draft or resolved saved source, Action, Saved-source availability.
- **Detail facts:** evidence includes actual request text, dates, agents, and projects.
- **Badges:** Suggested, Draft, Saved to Library, Saved source missing. Saved to Library requires resolving a Library source, not merely a nonempty saved path.
- **Actions:**
  - Primary **Draft with AI**, then **Edit draft** or **Save to Library…**, then **Open saved skill**, depending on state.
  - Supporting redraft, add saved skill to a destination, add to skillset, and dismiss act on explicit targets.
  - Saving alone does not install the skill.

Similar pairs:

- **List item:** both names, similarity score, and shared terms. This is a pair, not a single skill or a suggestion. No reader, usage, or duplication claim follows from its score.
- **Detail order:** Both skills and sources, Text comparison and similarity evidence, Action, Optional merge preview.
- **Actions:**
  - Primary **Compare skills**.
  - Supporting **Open first skill**, **Open second skill**, **They're different skills**, and **Review merge…** when eligible.
  - Similarity is a text signal. Merge review names the kept and replaced sources, affected readers, and preserved aliases before application.

### Badge, action, and data rules

Status pills are labels; action chips are focusable verb buttons. A status such as **In Library** never doubles as an undisclosed toggle. Actions require valid targets and capabilities; protected or unavailable targets expose an explanation and recovery route.

Every reader, evidence and assignment group is displayed within the Settings-enabled tool selection. Settings retains all supported toggles. Global and project filters clear a tool when it is disabled; normal addition and assignment choices omit it. An empty reader group says **Not available to enabled tools**, without claiming physical uninstallation. Disabling does not uninstall, unassign or rewrite existing copies. Existing disabled assignments remain recorded and can be managed after enabling that tool again. Reviews disclose when actual shared-reader effects extend beyond the displayed tools; complete reader sets remain part of operation validation. AI engine choices are separate from enabled skill-tool visibility.

Reader groups state their scope: **Available to** for a location's entries, **Available from this source** for proven source links, or **Available across copies** for an explicitly name-wide union. **Evidence from** describes suggestion/history agents; **Assigned to** names collection destinations. Never flatten project-local and inherited readers into an unexplained source-specific claim.

Missing source, unavailable project, absent installation and absent chat evidence are different states. Modified requires a baseline or receipt; differing same-name hashes only prove differing copies. Independent project/agent copies need separate reviewed updates. An upstream update creates no new agent link or skillset membership; skills inside an already linked parent can nevertheless become readable by that parent's readers.

Current global and project inventories group skills by name. Source-specific operations must additionally retain repository/ref/relative path or copy/target path. Grouped chat tallies do not provide per-source counts. Never invent author/edit history, source provenance, update freshness, or agent loading precedence from file names or matching descriptions. Show unavailable evidence explicitly when needed for a decision.

Cross-perspective links retain the selected skill and source where possible, plus explicit agent/project/collection context. If that source is unavailable in the next view, explain the loss of resolution rather than silently selecting another same-name copy.

## Target verification cases

The six-perspective implementation requires checks beyond the existing shared-control tests.

- The same skill appears in each applicable perspective with the same identity and appropriate contextual information.
- Rows and details present the intended badges and actions for each perspective, including Storage's three subviews.
- Every applicable agent badge remains visible at narrow widths, including shared-reader cases.
- Discovery distinguishes an imported source from an installation of another copy with the same name.
- Tool availability remains distinct from skillset assignment and recorded use.
- Project removal leaves inherited Global installations unchanged.
- Skillset membership removal leaves installed copies unchanged until an explicit reviewed operation.
- Saved ideas expose installation actions only after resolving a real saved source.
- Cross-perspective navigation preserves the intended skill, source, agent, and workspace.
- List headers carry shared context; rows keep full paths, receipts and snapshots in details while displaying every relevant reader badge.
- Installed entries default to inspection; similarity pairs default to comparison. Removal and merge require explicit secondary actions and reviews.
- Suggestion evidence agents, source readers and assignment destinations have distinct labels.
- A preferred-source change states its app-wide effect on future plans and leaves existing copies unchanged.
- Unchecked, pinned, moved-tag, missing-baseline and locally modified source states never appear as an unsupported Up to date or safe-to-replace claim.

These are implementation acceptance criteria, not a record of completed tests.

## Window structure

Dashboard uses a sidebar and a report pane. Other destinations generally use a sidebar, a content list, and a detail pane. The search field filters the active non-Dashboard destination. `⌘F` focuses search.

The sidebar has a minimum width of 210 points and an ideal width of 230 points. A status panel appears at its bottom. Group sections have disclosure controls.

## Sidebar destinations

The destinations appear in this order.

| Destination | Content |
| --- | --- |
| Dashboard | Recorded-use summaries and library review. Opens by default. |
| Discovery | Git repository and local-folder sources, their skills, and update workflows. |
| Library | Reusable central, draft, and shared skill sources. |
| Global | Home-level skill installations and agent availability. |
| Projects | All projects, registered workspace folders with path subtitles, and Register project. |
| Chat activity | Used in 2+ chats, Used in 1 chat, and No recorded use within the selected scope. A caption, **Every skill, not only Library**, names the scope. |
| Plugins | Installed plugins for enabled tools, with read-only details. |
| Skillsets | Named collections, New Skillset, and Import Skillset. |
| Ideas | Suggestions and Similar skills. |

Library and Global can contain the same skill. A Chat activity count is separate from installation status. Project entries distinguish duplicate folder names with their paths.

## Shared selection controls

The controls are defined in [Components.swift](Skillscout/Components.swift).

| Control | Appearance and behavior | Current uses |
| --- | --- | --- |
| `ChoiceChips` | Labelled capsule buttons that wrap. The selected choice has a checkmark, stronger text, and accent styling. | Source, sort, period, project scope, repository filter, engine, history range, and draft destination. |
| `AgentChoices` | Enabled-agent chips plus All enabled agents. Each agent has its name and symbol; callers supply the enabled list explicitly. Global adds optional inventory counts without changing choice identities. | Global, projects, and Dashboard. |
| `SearchChoice` | Labelled button with the current value, optional subtitle, and search symbol. Opens a searchable panel. | Destinations, projects, skillsets, sources, files, and repository versions. |
| `ChoiceAction` | Named action button with a searchable choice panel. Choosing a result invokes its action. | Add to skillset, choose source, and remove from an agent. |

Each `ChoiceOption` has a typed value and title, with optional detail, symbol, and tint. Selection controls update caller-owned bindings. Action controls invoke caller-owned closures.

The Individual skills and Skillset choice remains a segmented control. The merge flow also retains its short segmented name choice. Context menus and secondary action menus remain available.

## Search panels

The panel searches result titles and detail text. Rows show the title, optional symbol, and up to three lines of detail. A checkmark identifies the current selection, and a tinted background identifies the keyboard-focused result.

The panel content width is 360 points with 14 points of padding. Its result scroll region has a maximum height of 280 points.

| Input or state | Result |
| --- | --- |
| Open or reopen | The search field receives keyboard focus. |
| Type a query | Results narrow by title or detail. The selected value stays unchanged. |
| Down Arrow or Up Arrow | The focused result moves within the matching list. |
| Return | The focused matching result is chosen and the panel closes. The parent default action is not invoked. |
| Return with no results | No selection or action occurs. |
| Escape or close button | The panel closes without changing the selection. |
| Choose a row | The value or action is applied once, then the panel closes. |
| Empty options | The panel displays No choices available. |
| Unmatched query | The panel displays No matching choices. |
| Unavailable selected value | The trigger displays a choice placeholder and exposes No available selection to accessibility. |
| Disable the control while open | The panel closes and rejects selection or action callbacks. |

## Library and Global

Skill-list headers put **Sort** (Newest, Name, Use) and, where the list counts a saved scope, **Period** on one row as compact menus, with the **Project** search choice below. Only the list header has Project and Period; the skill detail states the scope in its Usage sentence and has no scope controls of its own. A chat without a recorded folder belongs to **Chats without a project folder**. Relevant lists also have Show choices for All skills, Your skills, and Plugin. Global adds System while **Show system skills** is enabled. Global omits project and period controls in both its list header and skill detail. A Library with no skills yet shows only **Build your skill library**, with **Browse Discovery** and **Add local folder**, and no sort or scope controls. Its recorded-use counts and Use sorting cover all loaded history for enabled agents, narrowed only by its Agent selection. Filters retained in other usage screens do not affect Global.

Global adds an Agent chip group; **Add skills…** is in the toolbar. Selecting an agent shows its assigned skillset count and **Manage…** when collections exist. Availability follows Settings-enabled agents. System skills are hidden by default in Global, including when an Agent filter is selected. **Show system skills** is a persisted toggle, and the System source chip is available only while it is on. A separate count shows system-only skills in the selected reader scope. Rows and details label them **System · Managed by [tool]** and explain protected management. [DESIGN.md](DESIGN.md#system-and-plugin-sources) defines the classification and which totals exclude these skills.

Each Global Agent chip displays its non-system skill count, including zero. **All enabled agents** displays the unique total across those readers. One line states the selected scope's globally available total and, after a dot, the system-only count; **Show system skills** sits below it. Counts include personal, shared, and plugin skills. Search and Show filters narrow rows without changing inventory totals. Shared skills count for each agent that can read them, but only once in the combined total. Counts update with the scanned inventory and Settings-enabled agents.

Skill rows show the name, description, usage information, and agent badges. Badges flow left to right with 4-point spacing (`WrapLayout`) and start a new line only when a row is full; every badge group in the app uses the same layout.

The skill and project list columns have a minimum width of 280 points and an ideal width of 340. A skill-list header takes its natural height, up to the smaller of 360 points or 55% of the list pane, and scrolls beyond that. The skill list occupies the remaining area.

Skill details present installation availability, sources, skillset membership, recorded use, contents review where applicable, and locations. Actions follow the selected list context. Only Global shows removal. Each removal link names every agent that loses the skill: **Remove from Codex…**, **Remove from Codex and Cursor…** when another agent reads the same folder, or **Remove from Codex and 7 other agents…** for a widely shared folder; the confirmation lists them all. In Global, plugin-supplied skills name their supplying plugin and offer **View plugin…** beside availability. The plugin sheet shows its provider, included skills, locations and read-only management guidance. Plugin and built-in skills cannot be removed individually in Skillscout; their providers are managed in the original tool. Personal copies retain their reviewed removal action even when plugin access remains.

## Skill details by view

`SkillDetail` takes its section list from the view it is shown in, so each view leads with its purpose and omits actions that belong elsewhere.

| View | Sections, in order | Actions |
| --- | --- | --- |
| Library | Problems, Sources, Contents, Skillsets, Usage, What it does, SKILL.md | Add skills, Add to skillset, Edit, Rename, Manage in Global… |
| Global | Problems, Global availability, Contents, Skillsets, Usage, SKILL.md | Add skills, Add to skillset, Remove from [agent], Move to Library, View plugin… |
| Chat activity | Usage, Sources, SKILL.md (collapsed) | Open in Library, Manage in Global… |
| Skillset | Skillsets (this membership and its source), Sources, Usage, SKILL.md | Remove from [skillset] |
| Discovery skill | Contents, Problems, Sources, What it does, SKILL.md | Open in Library |
| Plugin skill | Contents, Sources, Usage, SKILL.md | None; plugins are read-only |

Edit and Rename appear only in Library. A personal Global skill outside Library says **Move this skill to Library to edit or rename it.** The Skillsets section lists the skillsets that contain the skill; **Add to skillset** sits with the other installation actions, and there are no per-skillset toggles. The Chat activity toolbar offers **Open in Library** and **Manage in Global** instead of Add, Edit and Rename.

The Library folder, `~/.config/skillscout/skills` with its drafts, is Skillscout's own storage. Only Library shows its path, reveals it in Finder, or opens its `SKILL.md` in an editor. Every other view, sheet and the command-line tool names it instead, as **Library · repo/skill**. Outside Library, Sources hides the Library copy and lists the agent links that point to it, a skill stored only in Library says **Stored in Library. Not added to an agent.**, its SKILL.md is read-only with **Open this skill in Library to edit it.**, and the menu offers **Open in Library**. The command's `--json` output keeps full paths for scripts.

## Repository updates

Repository update review has two steps. **Compare file** selects a changed file and shows Base, Mine, and GitHub/Incoming contents. Keep mine and Use GitHub/Incoming select complete versions; Merge opens `PlainTextEditor` with selectable reference versions. Conflicts must be resolved before **Review choices**.

Final review shows actual added, changed, and removed files, preserved local edits, merged paths, content findings, and **Read file** for the approved contents. **Back** discards the reviewed result and returns to choices; **Apply update** validates and applies it. Impact lists linked agents, independent copies, project copies and their protected edit state, unchanged collection membership, and new skills awaiting assignment. All reader badges remain visible.

## Projects

The project list shows registered folders. A selected project shows its name and path, a refresh button, **Project overview**, **Add skills…**, and the same **Manage…** skillset control used by Global.

Agent chips filter availability. Show chips switch between **Available here** and **Project only**. The **Period** menu scopes recorded use. **Add skills…** comes first in the header, with **Project overview** beside it, and the controls wrap rather than truncate. The header scrolls within the smaller of 340 points or 55% of the available list-pane height.

Rows appear once per skill and can show both **Project** and **Inherited from Global** labels. The detail pane separates local copies from inherited installations. **Manage in Global…** opens the inherited skill in Global with the relevant agent filter.

The overview shows individual additions, read-only applied skillset summaries, native roots, inventory issues, and recovery state. Skillset actions live in **Manage…**, using the [shared management screen](#shared-skillset-management). Unavailable projects have an explicit unavailable state. Filtered empty lists offer Reset filters when applicable. After an apply, the overview shows one summary line with **Dismiss**, and the per-skill results sit under **Details (N)**.

## Skillset membership view

Selecting a skillset shows its members, **Edit…**, assignment summary, **Install skillset…**, and Sort choices. The list and member details omit **Project** and **Period** controls. Chat counts, **Use** sorting, and usage labels cover all loaded history for enabled agents. Saved project and period filters from other screens do not change this view.

**Edit…** changes membership. **Install skillset…** applies the skillset to a destination, Global or a registered project. It isn't called **Add skills…**, because on the same screen the toolbar's **Add skills…** installs the selected skills. Usage filters remain in Dashboard. Viewing or sorting members does not alter assignments or applied project snapshots.

## Shared skillset management

Global and projects open the same `SkillsetAssignmentsSheet`. Global's **Manage…** uses the selected agent. A project's **Manage…** carries its project and current agent filter. The project screen shows the name, folder, readable agent groups, target folder, and affected-agent badges. Shared folders also disclose effects on disabled readers.

The screen lists available collections and their assignment state. Project rows also show the current member count and applied snapshot count. Missing collections retain their project assignment snapshot and **Unassign…** action.

| Control | State and result |
| --- | --- |
| **Apply…** | An unassigned collection opens a review for the selected destination. |
| **Apply changes…** | Changed membership opens an update review. Existing snapshots remain until application. |
| **Review…** | An assigned collection opens its current application preview. Global can show **Retry…** for incomplete assignments or recorded issues. |
| **Unassign…** | An assigned collection opens an unassignment review. Global exposes this through the row's More actions menu; projects show it beside the row action. |
| **Done** | Closes the management screen. |

Global's final review uses **Apply** or **Unassign**. Project review uses **Apply changes** or **Unassign and apply changes**. Opening a review or cancelling it does not change installations or assignment snapshots.

Unassigning preserves the central skillset. Installations still needed by another skillset remain. Removable installations owned by Skillscout move to Trash; modified or unowned project files remain in place. Project recovery, an unavailable folder, or an incompatible target prevents application. Assignments for disabled tools remain stored.

## Add and remove flows

**Add skills…** opens a destination choice and an Individual skills or Skillset segmented choice. The current workspace supplies the default destination. Opened from a selection, it names the selected skills with **Change skills…** instead of showing the full list again. **Continue** opens the corresponding review, where agents start unticked unless the sheet came from one Global agent or only one agent is enabled. A warning that a shared location also reaches disabled agents names them.

Global review shows selected agents, affected readers, source choices, contents inspection, and per-agent results. After a run, a line such as **1 added · 1 needs your choice below.** sums it up; **Add remaining** handles the rows still open, and once none are, **Done** becomes the main button. Conflicts have Keep existing and Replace choices. Replacement has a separate confirmation that identifies the existing entry moving to Trash.

Project review shows the target group and changes before Apply. Shared and Claude targets identify every agent that reads their project folders. Changed previews, conflicts, and recovery state prevent unsafe application.

**Remove from project…** reviews the selected project target. Inherited Global installations remain separate. Modified or unowned project files remain with an explanation. Skillset membership removal changes the collection rather than uninstalling the skill.

## Other screens

| Screen | Main UI |
| --- | --- |
| Dashboard | Agent, project, and period controls; recorded-use totals; ranked skills; library review for similar skills, differing copies, and source contents. |
| Discovery | Git repositories and Local folders choices; source list; repository details; skill preview; import, update review, and version selection. A repository in Library leads with **Add skills to agents…**, which opens Add skills with its skills selected and their sources set to that repository. **Check all for updates** in the toolbar shows "Checking N of M…", then a summary of updates, failed checks and unchecked local folders, and switches to **Updates available** when any are found. |
| Skillsets | Membership editor, source choices, shared Global/project assignment manager, reviewed apply and unassign actions, and import or export actions. |
| Suggestions | Repeated-task ideas, AI draft generation, save-destination chips, and actions for the saved skill. |
| Similar skills | Similar pairs, comparison details, and a reviewed merge flow. |
| Plugins | Agent, marketplace, version, folder, skills, hooks, servers, monitors, and executables. No plugin installation controls. |
| Settings | Tool toggles, AI engine chips, history choices for 30, 60, 90, or 180 days, automatic-analysis settings, and Repair Library, which renames older repository folders and moves only links to missing Library skills to Trash. |

## Visual styling and accessibility

The app follows system light and dark appearance. It uses semantic foreground styles, system accent color, native text styles, and SF Symbols. Paths and commands use monospaced text where appropriate.

Choice chips have 8-point horizontal padding, 5-point vertical padding, and 5-point wrapping gaps. Search triggers have an 8-point corner radius. Result rows have a 7-point corner radius and 9-point padding.

Selected chips expose a selection value and combine a checkmark with color. Search triggers expose the current value. Result buttons expose Selected or Not selected. Help text provides full choice details when labels or paths are truncated.

`PlainTextEditor` handles `SKILL.md` editing. The editor preserves command text without system smart-quote or smart-dash substitutions.

## Source map

| File | Responsibility |
| --- | --- |
| [ContentView.swift](Skillscout/ContentView.swift) | Sidebar, routing, shared list headers, toolbar, and presentations. |
| [Components.swift](Skillscout/Components.swift) | Choice controls, wrapping layout, agent badges, detail sections, and plain-text editing. |
| [SkillViews.swift](Skillscout/SkillViews.swift) | Skill rows, adaptive agent badges, details, editing, and rename UI. |
| [ProjectViews.swift](Skillscout/ProjectViews.swift) | Project inventory, detail, contents, application, and recovery UI. |
| [SkillActionViews.swift](Skillscout/SkillActionViews.swift) | Add-skills entry, Global review, source inspection, and usage controls. |
| [RepositoryViews.swift](Skillscout/RepositoryViews.swift) | Repository lists, details, and version choice. |
| [RepositoryUpdateViews.swift](Skillscout/RepositoryUpdateViews.swift) | File decisions, manual merge editor, and final update review. |
| [RepositoryUpdateImpactViews.swift](Skillscout/RepositoryUpdateImpactViews.swift) | Linked readers, independent copies, project copies, and new skill impact. |
| [ReportsView.swift](Skillscout/ReportsView.swift) | Dashboard and report filters. |
| [SkillsetViews.swift](Skillscout/SkillsetViews.swift) | Membership and assignment management. |
| [SettingsView.swift](Skillscout/SettingsView.swift) | Tool, AI, analysis, and maintenance settings. |

## Verification reference

The native workflows and renders use made-up home folders and separate application identities.

```sh
python3 scripts/functional-check.py
python3 scripts/functional-check.py --projects
python3 scripts/functional-check.py --selectors
```

The selector suite compiles the actual shared controls and models. It drives native mouse and keyboard events, then checks binding and action outcomes. Render outputs live under the corresponding suite's `build` folder.

UI changes also require a build and an opened app, with inspection of narrow and short windows in both appearances. [AGENTS.md](AGENTS.md) describes build and installation verification. [Selection verification](tasks/selection-redesign-verification.md) records the completed redesign checks.
