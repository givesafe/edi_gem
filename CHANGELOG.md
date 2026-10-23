## [Unreleased]

### Proposed (in the working tree, not yet reviewed by Danny)

The caller contract for each is in the README's "V1 reference".

- `Response#provider_standing`: `:refused`, `:accepted` or nil, what an answer says of our
  provider's standing with the payer, so a caller never reads the refusals and the state for it.
- `Response#checked_plan`, `#medical_plans(asked:)`, `#discovery_verdict` and `#error_code`;
  `CheckedPlan#verdict` and `#verdict_code`; `EdiGem::CheckedPlan`, `EdiGem::MedicalPlan` (both
  `EdiGem::AnsweredPlan`) and `EdiGem::Verdict`. A caller reads a check or a discovery in coverage
  terms and never reads a benefit line's codes itself.
- `MedicalPlan#payer_id`: Stedi's payer ID for a plan's payer code, from Stedi's payer
  directory (`Source::Base#payers`, `#payer_id_for`; `EdiGem::ListedPayer`). One search per code
  for the source's lifetime; not billed.
- `Source::Base#archived` (the common name for `archived_discovery`) and `#archived_question`,
  which reads a kept discovery request back as an `Inquiry::Question` (`Person::Asked` and the day
  asked about). `Inquiry::Discovery#question` builds the same from an inquiry.
- `Identification#match`, `#mismatched?`, `#fields`, `#reason` and `#answered_as`, with the
  payer's refusal of the person (`EdiGem::PersonRefusal`) winning over our comparison.
- `Identification#moved?`, reviewed with `Response#identify`, is removed: no caller reads it.
  `#answered_as` says which part of the answer the person came back in.
- `Identification#given_fields`, `Address#compare` and `EdiGem::LastFour`: a given address and
  the last four of an SSN are compared with what the payer holds, and never change the match.
  `Person#ssn_last_four`, `#relationship` and `#born_on`. `Identification` is its own constant.
- `Inquiry#idempotency_key` and `#fingerprint` (`EdiGem::RequestKey`): keys made from what a
  question asks, so the details themselves are never stored.
- `Coverage.context(code)`: what EB01 5, 7 and 8 say beyond the status.
- `Batch::Status#progress`, `Batch::Check#completed?`, `Error#code` and `Fault#code`.
- `Source::Mock` (`Source.for(:mock, ...)`): Stedi with discovery answered from code, since
  Stedi's test mode answers no discovery.
- `EdiGem::ArchiveFailed#retryable?`: whether the same archive read or write may succeed later.
  True for a network failure reaching an S3 bucket (timeouts, socket, connection, IO and
  TLS errors), for an S3 bucket that answered 500, 502, 503, 504 or 429, and for a
  local read the system interrupted; false for a missing or refused object, an S3 answer that is
  not readable HTTP, and every other local failure. The class and its ancestry are unchanged.
- One existing behavior changes: `Archive::S3` raises `ArchiveFailed` only for the network
  failures above and for an answer that is not readable HTTP (`Net::HTTPBadResponse`,
  `Net::HTTPHeaderSyntaxError`, with the message "answered with no readable HTTP"). Any other
  exception from the HTTP client, such as a `TypeError` or `ArgumentError`, was wrapped as
  `ArchiveFailed` and is now raised as itself, so a defect does not read as a missing body.
- A second behavior changes: `Archive#fetch` (and so `archived`, `archived_discovery` and
  `archived_question`) raises `ArchiveFailed`, not retryable, in place of `ArgumentError` for a uri
  (nil included) the archive did not make: an object in another bucket, or a uri that is not a
  local archive's. The messages are the same and nothing is sent. The uri is stored data, not a
  defect in the call.

### Reviewed

- Names are sent in capitals without accents (`Identity.plain`), in Stedi bodies and in a 270.
  This changes what an existing call sends; payers differ on accents, so none are sent.
- `Inquiry` takes `dependent:`, the patient when they are on the subscriber's policy. Stedi sends
  it as the one `dependents` entry (with `individualRelationshipCode` when the relationship is
  :spouse, :child or :other_adult); a 270 writes it at the dependent level (HL 23, NM1*03, INS)
  with the trace, plan date and service types. A discovery refuses one.
- `Response#people`, `#subscriber_person`, `#dependent_people` and `#identify`: who the answer
  names (`EdiGem::Person`, with the relationship and maintenance codes), and which of them is the
  person asked about. `Schema#person` declares where a schema finds them.
- `EdiGem::Identity.compare`: the field-by-field comparison `identify` uses, for a caller to use on
  its own records too.
- The `:stedi` schema reads `dependents[].aaaErrors` in the dependent lane. The `:x12_271` schema
  reads a dependent's lines, dates and refusals (2110D, 2100D). Discovery benefits carry the
  matched person's middle name, relationship code and maintenance codes.

All additions; one existing call changes: a Stedi check to a payer `sources.yml` declares as
needing a credential (Medi-Cal, `100065`) now raises `EdiGem::CredentialMissing` before it is
sent when no credential is given, as an inquiry's `required_credentials` already did.

- `payer_credentials` in `sources.yml` names, by the source's payer code, the Credential keys a
  payer needs. `Source::Base#required_credentials(payer_code)` and `Policy#credentials_for`
  read it. Stedi's Medi-Cal (`100065`) needs `portal_password`, its PIN.
- `Inquiry::Eligibility` takes `credential:`, the payer's secrets for that inquiry, used in place
  of the source's own. Each payer issues its own, so one source can check more than one payer, and a
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
