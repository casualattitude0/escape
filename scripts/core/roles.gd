class_name Roles
extends RefCounted

## Role and match-result identifiers. Using these constants instead of bare
## strings keeps "runner"/"hunter" typos out of the codebase.

const RUNNER := "runner"
const HUNTER := "hunter"

# Winner values (note: the Hunter team win is plural).
const WIN_RUNNER := "runner"
const WIN_HUNTERS := "hunters"
