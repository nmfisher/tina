# Provider spend

`tina/providers` accounts for each opened provider attempt once. Reported usage
is measured spend, including usage reported with an error; explicit zero usage
stays zero. A failed, truncated or cancelled attempt without reported usage
books an input estimate (UTF-8 request bytes divided by four, rounded up).
Successful replies without usage remain unreported. Estimates are conservative
accounting, not billing receipts, and appear separately in the status strip.

Measured plus estimated spend counts toward session, turn, child and global
ceilings. Queue cancellation and preflight refusals spend nothing. A failed
attempt can exhaust a ceiling before pool failover opens another request.

Every settled attempt is recorded as `usage_recorded` through the loop's single
log writer, including child spend in the parent's global budget. These entries
do not become model messages. Resume uses them for covered turns and falls back
to `turn_ended` usage for older/imported turns, without double counting. Unknown
historical failed spend cannot be recovered. Stores containing the new entries
require this version or newer to resume; v0.9.0 predates this entry type.
