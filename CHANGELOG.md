## [Unreleased]

All additions; one existing call changes: a Stedi check to a payer `sources.yml` declares as
needing a credential (Medi-Cal, `100065`) now raises `EdiGem::CredentialMissing` before it is
sent when no credential is given, as an inquiry's `required_credentials` already did.

- `payer_credentials` in `sources.yml` names, by the source's payer code, the Credential keys a
  payer needs. `Source::Base#required_credentials(payer_code)` and `Policy#credentials_for`
  read it. Stedi's Medi-Cal (`100065`) needs `portal_password`, its PIN.
- `Inquiry::Eligibility` takes `credential:`, the payer's secrets for that inquiry, used in place
  of the source's own. Each payer issues its own, so one source can check several payers, and a
  batch can carry a different credential on each item.
- `EdiGem.reveal = true` makes `inspect` and `pp` print secrets and PHI in full, for hosts with
  no real member data and no production key. Off unless set to `true`.
- Sources, `Source::Connection`, `Archive::Signature`, `Core::Request`, `Document` and its
  records, and `Response` no longer print their keys, headers, bodies or details; they print
  names, sizes and states, as `Subscriber`, `Payload` and the others already did.
- `EdiGem::Source.for(name, **config)` builds a source by name (`:stedi`, `:office_ally`,
  `:optum`), and `Source.names` lists them. An unknown name raises `EdiGem::UnknownSource`.
- `Policy.for(source, retry: {...})` and `Policy#with(retry: {...})` merge a caller's retry
  settings over a source's policy, key by key. Only `retry:` is accepted, and only the keys of
  the `retry` block in `sources.yml`; anything else raises `ArgumentError`.
- `batch_checks(batch_id, archive: { name: "stem" })` files each item's raw answer on its own,
  under `<stem>_<identifier>`, as feature `batch_check`. `Batch::Check#raw` is the item as the
  vendor sent it, and `Batch::Check#stored` is where the archive kept it (an `Archive::Stored`,
  or nil). `Source::Base#batch_checks` gains the `archive:` keyword.
