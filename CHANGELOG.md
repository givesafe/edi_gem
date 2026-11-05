## [Unreleased]

### Proposed (not yet reviewed by Danny)

The caller contract for each is in the README's "V1 reference".

- `Finding` names a payer's silence itself: `payer_down` when Stedi says to ask again (42, 80),
  `payer_not_connected` for a 79 alone, and `our_fault` for our setup refused (41, T4) or a 42
  not to resubmit (follow-up C, N or S). Each was `no_answer`, for the caller to tell apart.
- `Finding.of_plan(plan, on:)` reads a discovery's found plan: its lines decide, and with none
  deciding, its payer's refusal of our provider is `provider_refused`. `MedicalPlan#rejections`.

- `Response#warning_codes`: the codes of Stedi's `warnings`, on a check and a discovery, for the
  caller to log (empty when none). Stedi: "a check can succeed while missing information you meant
  to include". None of them decides the answer.
- When the person's lanes hold several refusals, the one that decides no longer depends on their
  order: a death before the day asked, then the person held differently, then not on this ID, then
  what we sent. [15, 72] and [72, 15] both read `not_on_this_id`, where the first read `our_fault`.
- A payer's refusal for want of the subscriber's gender (AAA 74) is `our_fault`, where it decided
  nothing and the answer read `no_answer`. Stedi: "The payer requires the subscriber's gender code";
  the request is ours to correct.
- A discovery Stedi couldn't complete (`ERROR`, HTTP 502) is read from its body, where the 502 alone
  made it `vendor_unavailable`, retried automatically. With AAA refusals in its `errors` they are the
  answer, read as a success's are; without them it is `vendor_error`, sent once and filed. A 502 whose
  body isn't JSON is still `vendor_unavailable`. Applies to the discovery and its results.
- A discovery's found plan keeps its payer's refusal of our provider
  (`items[].subscriber.responseProvider.aaaErrors`, and `dependent`'s) as `FoundPlan#rejections`, where
  it was not read. It is not a refusal of the whole search, and the same refusal repeated in the
  top-level `errors` is not counted twice. One payer refusing our provider says nothing of the others.
- `Finding.of_search` reads a discovery that found no plan as the new `nothing_found`, where it read
  `not_covered` (Danny, 2026-11-05). Stedi: a discovery "can return zero matches for a patient even
  when they have active coverage", so finding none says nothing about whether they are covered.
- `Finding.of_check` reads a settled answer with no lines and no refusal as `no_answer`, where it read
  `not_covered`: nothing in it says the person isn't covered. A death before the day asked (AAA 61) is
  still `not_covered`.
- The S3 archive reads its keys from `AWS_ACCESS_KEY` and `AWS_SECRET_KEY`, the names the backend
  already uses for its uploads (Danny, 2026-11-04), where it read `AWS_ACCESS_KEY_ID` and
  `AWS_SECRET_ACCESS_KEY`. An environment with only the old names now gets no archive, and a send that
  asks to archive raises `ArchiveNotConfigured`. `AWS_SESSION_TOKEN`, `AWS_REGION` and
  `AWS_DEFAULT_REGION` are unchanged.
- A send that asked to archive no longer loses the paid answer when the archive write fails
  (`ArchiveFailed`, for example S3 unreachable): `Responses#from` returns the Response unstored
  (`stored` nil, `archived?` false) with the failure as `Response#archive_failure`, for the caller
  to report (Danny, 2026-11-01). Before, the failure raised after Stedi had answered. The gem does
  not retry the write. A batch status page (`batch_checks`) still raises: it holds no answer, and can be read again.
- `Provider` can be built from `npi:` alone, and sends only the NPI to Stedi. Stedi finds the
  provider by NPI and advises leaving the name out (Danny, 2026-10-31). The X12 270 writer now refuses
  a provider with no name, since NM103 carries it; before, `Provider` refused one when it was built.
- `Provider` takes `address:` (an `Address`), sent as Stedi's `provider.address`, and left out when
  nil, as `taxId` is. Stedi says to send either only when the payer requires it.
- `Response#provider_standing` reads `:needs_provider_details` when every refusal about our provider
  asks for our tax ID and address (`Rejection#provider_details_wanted?`: AAA 97 in any lane, AAA 15
  in the provider's), where it read `:refused` before.
- `Response#provider_standing` reads `:not_connected` for an AAA 79 with nothing beside it that
  says to ask again (`Response#not_connected?`), where it read nil before. Stedi: "Don't
  automatically retry… contact Stedi support".
- `Response#provider_standing` reads `:accepted` for `not_identified`, where it read nil before: a
  payer that could not match the person looked them up for our provider.
- Stedi busy on a real-time check (HTTP 429, `rate_limited`) is retried until two minutes after the
  first send, past `attempts`, as Stedi's eligibility troubleshooting page says for a 429 ("Retry
  immediately") and a 42 ("for up to 2 minutes"). The pauses are the backoff's, or Retry-After.
  A new `retry` key, `retry_until_end`, names the kinds retried this way (`Policy#retry_until_end?`);
  a send with no end (`retry_until`) still stops at `attempts`.
- A discovery send and a batch submit are no longer sent again after our own timeout: Stedi
  doesn't say a second one is safe or unbilled. Their other failures are retried as before.
- A discovery's results are polled under their own operation, `discovery_results` (same path and
  timeout), so a timed-out poll is still retried and the polls pace apart from the sends, as
  Stedi limits the two endpoints apart. The mock answers both.
- `batch_checks` and `batch_results` take `only:` (identifiers): the items sent under those alone are
  read and filed, so a caller polling a batch files only the answers it hasn't taken yet.
- `Batch::Status#answering?` and `#done?`: when a batch's results are worth reading (a success or
  error count above zero) and when polling can stop (nothing in progress after a check was
  processed, or a finished status), as Stedi's batch refresh guide says. `#progress` reads a batch
  done by its counts before its status caught up as completed, with errors when any check ended in one.
- `Response#deciding_rejection`: the refusal that decided the state, read in the state's own order,
  not the first one listed, so a refusal listed ahead that decides nothing no longer hides the one
  that does. `#error_summary` and `Rejection#summary` say it in codes alone ("AAA 62 at subscriber, follow-up C"), never Stedi's free text.
- `Response#our_setup_refused?` and `Rejection#our_setup_refused?`: a 41 or a T4 in the payer lane,
  which Stedi reads as our NPI, credentials or the payer ID we sent. The state stays `payer_silent`.
- AAA 60 reads as `birth_date_after_day_asked`, no longer `date_out_of_range` (kept for 62 and 63).
  AAA 64 reads as `dependent_id_required`, no longer `member_id_invalid` (kept for 72): Stedi says
  the payer needs another dependent identifier, so it is `our_fault` and its answer `rejected`
  without lines, no longer `not_identified`.
- AAA 58 reads as `invalid_date_of_birth`, no longer `date_of_birth_mismatch` (kept for 71): Stedi
  says the birth date is missing or malformed, so it is `our_fault` and its answer `rejected`
  without lines, no longer `not_identified`.
- A real-time check's HTTP 400 that holds Stedi's AAA refusals is read as a 200's is, so a 79 there
  is the payer Stedi couldn't connect to, not a `malformed_request` Fault. A 400 holding no AAA is
  still that Fault. New: `errors.answer_in_status` in `data/sources.yml`, `Policy#answer_in_status?`,
  `Policy#fault_for_status`, `Rejection#aaa?`, `Codec::AAA03_VALUES`.
- `PersonRefusal.refusal_among`: the refusal `.finding_among` reads.
- `Fault#to_rejection` is removed: no caller read it.
- Names sent as Stedi asks: a suffix (JR, SR, I, II, III, IV, V, with or without a period)
  goes in the request's `suffix` (X12 NM107), for the subscriber and dependents, not the last name;
  titles aren't sent; `~ * : ^ >` are removed from every name. `Identity::SUFFIXES` is split into
  `SUFFIXES` and `TITLES`. New `Identity.payer_sent`, `.payer_sent_last_name` and `.suffix`.
- A suffix the payer sends apart (Stedi's `suffix`, X12 NM107) is read into `Person#last_name`.
  The mock echoes the suffix it was sent.

- `Response#provider_standing`: `:refused`, `:accepted` or nil, what an answer says of our
  provider's standing with the payer, so a caller never reads the refusals and the state for it.
- `Response#checked_plan(identification:)` and `#medical_plans`;
  `EdiGem::CheckedPlan` and `EdiGem::MedicalPlan` (both `EdiGem::AnsweredPlan`). A caller reads a
  check or a discovery in coverage terms and never reads a benefit line's codes itself.
- `EdiGem::Verdict`, `CheckedPlan#verdict` and `#verdict_code`, `Response#discovery_verdict` and
  `#reading` are removed: `Finding` holds the same meaning, and a caller derives its one word from
  it. `Finding#inactive?` keeps what the verdict kept apart (a plan that ended). `Finding.of_search` reads a discovery that found no plan; which
  found plans decide a discovery is the caller's, so the gem has no discovery fold.
- `PersonRefusal::FINDINGS`: what each refusal in the person's lanes says the answer found, read by
  `Response::State` and `Finding` alike. Beyond the identity codes, `78` (not in this group or plan)
  is `not_on_this_id`; what we sent (`15`, `33`, `56`, `57`, `60`, `62`, `63`, `64`) is `our_fault`, and
  its answer `rejected` when no line came with it; a death before the day asked (`61`) is
  `not_covered`.
- `MedicalPlan#payer_id`: Stedi's payer ID for a plan's payer code, from Stedi's payer
  directory (`Source::Base#payers`, `#payer_id_for`; `EdiGem::ListedPayer`). One search per code
  for the source's lifetime; not billed.
- Who an answer is about is the caller's reading: `checked_plan(identification:)` and
  `Finding.of_check` take any object answering `mismatched?`, `answered_as` and `match`, and
  the gem has no `Identification` or `Address#compare`. `Person#relationship`.
- `Inquiry#idempotency_key` and `#fingerprint` (`EdiGem::RequestKey`): keys made from what a
  question asks, so the details themselves are never stored.
- `Coverage.context(code)`: what EB01 5, 7 and 8 say beyond the status.
- `Batch::Status#progress`, `Batch::Check#completed?`, `Error#code` and `Fault#code`.
- `Source::Stedi#eligibility` asks again a payer that can't answer right now, as Stedi says:
  at once and for up to two minutes, unless a 42's follow-up is C, N or S (`AskingAgain`;
  `payer_pauses:`, `sleeper:` and `clock:` on `Stedi.new`). `Rejection#payer_unreached?` (a 42
  Stedi would ask again, an 80 or a 79), `Response#resubmission_refused?` (a 42 with C, N or S, which Stedi reads as a problem with the request,
  not a payer that is down; `Rejection#resubmission_refused?`) and `#ask_again?`;
  `Rejection#reason_code`. `Rejection#retryable?` follows Stedi's rule, and
  `#recognised?`, `RETRYABLE_REASONS` and `RETRYABLE_FOLLOWUPS` are removed. The eligibility
  timeout is 125 s, and the transport starts no retry past the two minutes (`retry_until:`).
- `Coverage::NOT_IMPLYING` includes `managed_care_coordinator`: an MC line on 30 alone no longer
  reads as active.
- A Medicaid plan is paired with an MCO's by the primary payer's name too
  (`FoundPlan#names_as_primary_payer?`).
- `AnsweredPlan#plan_ends_on` is nil for an end in the year 9999, a payer's placeholder.
- `Source::Mock` (`Source.for(:mock, ...)`): Stedi with discovery answered from code, since
  Stedi's test mode answers no discovery. Its payer-down answers (42, 80) carry a follow-up
  Stedi would ask again, and it asks a check once unless given `payer_pauses:`, so dev and spec
  runs never sleep.
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
- A second behavior changes: `Archive#fetch` (and so `archived_discovery`) raises `ArchiveFailed`, not retryable, in place of `ArgumentError` for a uri
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
