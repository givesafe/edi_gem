# edi_gem

One Ruby API for healthcare eligibility across clearinghouses. A source sends an eligibility
check, an insurance discovery or a batch of checks, and every answer comes back as the same
objects: a `Response` with a state, `Benefit`s and `Rejection`s. Callers never parse a 271.

## Status

For the Samaritan backend's engineers, who call the gem, and for the gem's maintainers. Owner:
Danny Sperry. The calls the backend makes are in "V1 reference" below.

Version 0.1.0, private; changes not yet released are in `CHANGELOG.md` under [Unreleased].
`Source::Stedi` is the working source. `Source::OfficeAlly` and
`Source::Optum` are stubs: each one is written from the vendor's published companion guide and
has never been called against the live service, and no trading partner agreement is held with
either vendor. The gem has no runtime dependencies.

| source | eligibility | discovery | batch |
|---|---|---|---|
| `Source::Stedi` | yes | yes | yes |
| `Source::OfficeAlly` (X12 in a CAQH CORE envelope) | yes | no | no |
| `Source::Optum` (bare X12) | yes | no | no |

## Install

```ruby
gem "edi_gem", github: "givesafe/edi-gem"
```

## Configuration

```ruby
stedi = EdiGem::Source::Stedi.new(api_key: ENV.fetch("STEDI_API_KEY"))
```

A source can also be built by name, so the clearinghouse is a value, not a class in your code:

```ruby
source = EdiGem::Source.for(:stedi, api_key: ENV.fetch("STEDI_API_KEY"))
EdiGem::Source.names    # => [:stedi, :office_ally, :optum]
```

`config` is whatever that source's initializer takes. An unknown name raises
`EdiGem::UnknownSource`.

To change how a source retries, merge your settings over its policy instead of rebuilding it:

```ruby
policy = EdiGem::Policy.for(:stedi, retry: { attempts: 5, backoff: 1 })
stedi = EdiGem::Source::Stedi.new(api_key: key, policy: policy)
```

Settings merge key by key, so `attempts` alone keeps the source's backoff. Only `retry:` can be
overridden, with the keys of the `retry` block in `lib/edi_gem/data/sources.yml`
(`attempts`, `backoff`, `multiplier`, `max_delay`, `jitter`, `retry_on`, `retry_until_end`: the
kinds retried until the send's end rather than `attempts` times); an unknown key raises
`ArgumentError`. An operation that sets its own `retry` in `sources.yml` keeps it.

A Stedi test key reaches test mode on the same host. Optional keywords: `credential:` holds the
per-payer secrets for one provider (`EdiGem::Credential.new(provider:, source: :stedi,
values: { portal_password: "..." })`), and `archive:` is where raw bodies are kept.

The archive defaults to `EdiGem::Archive.from_env`, which reads `EDI_ARCHIVE_TEMPLATE`:

- `s3://bucket/edi/$CLEARINGHOUSE/$YYYYMM/$FEATURE/$DIRECTION` writes to S3, using
  `AWS_ACCESS_KEY`, `AWS_SECRET_KEY` and optionally `AWS_SESSION_TOKEN` and `AWS_REGION`.
- `file:///var/edi/$YYYYMMDD/$FEATURE/$DIRECTION`, or a bare path, writes locally.

The template must place `$DIRECTION`. The gem fills `$CLEARINGHOUSE`, `$FEATURE`, `$DIRECTION`,
`$YYYY`, `$MM`, `$DD`, `$YYYYMM` and `$YYYYMMDD`; any other placeholder is filled from the values
you pass with each send. Nothing is archived unless a send asks for it.

`archive.fetch(uri)` reads back a body kept at a `Stored` uri. `stedi.archived_discovery(uri)`
reads a kept discovery answer into a `Response` again without calling Stedi (see "V1 reference").
A kept answer is read as it was recorded and never asked again.

A write or read the archive cannot complete raises `EdiGem::ArchiveFailed`, as does
`archived_discovery` when the body cannot be read. **(proposed)** Its
`retryable?` says
whether the same call may succeed later; the gem does not retry, and when to ask again is the
caller's to decide:

| archive | failure | `retryable?` |
|---|---|---|
| S3 | a network failure: a timeout (`Timeout::Error`, `Net::OpenTimeout`, `Net::ReadTimeout`), `SocketError`, a system call error (`ECONNRESET`, `ECONNREFUSED`, `EHOSTUNREACH`, `ETIMEDOUT`, `EPIPE`), `IOError` or `EOFError` | true |
| S3 | `OpenSSL::SSL::SSLError`, retried by choice: it does not say whether it will pass, and Net::HTTP itself retries it | true |
| S3 | an answer that is not readable HTTP (`Net::HTTPBadResponse`, `Net::HTTPHeaderSyntaxError`) | false |
| S3 | answered 500, 502, 503 (Slow Down included), 504 or 429 | true |
| S3 | answered any other status: 404 NoSuchKey, 403 AccessDenied, other 4xx | false |
| local | the system interrupted the read (`EAGAIN`, `EINTR`, `EBUSY`, `ETIMEDOUT`) | true |
| local | any other failure: a missing file, a refused permission | false |
| either | a uri (nil included) this archive did not make: another bucket, or not a `file://` uri; nothing is sent | false |

Any other exception from the S3 client (`TypeError`, `NoMethodError`, `ArgumentError` and the
like) is a defect in the call, not an archive failure, and is raised as itself. A local read
raises `ArchiveFailed` only for a system call error, so anything else is raised as itself there
too.

The S3 statuses follow AWS's retry guidance
([AWS SDKs retry behavior](https://docs.aws.amazon.com/sdkref/latest/guide/feature-retry-behavior.html),
[S3 performance design patterns](https://docs.aws.amazon.com/AmazonS3/latest/userguide/optimizing-performance-design-patterns.html)).
Only the status is read, so a 400 `RequestTimeout`, which AWS retries, is not retryable here.
An `ArchiveFailed` raised with no flag is not retryable.

## Usage

```ruby
provider = EdiGem::Provider.new(npi: "1999999984", organization_name: "Example Clinic")
# Stedi: send taxId and address "Only include if required by the payer"; address needs at least
# address1 and city. Each is left out of the request when nil.
EdiGem::Provider.new(npi: "1999999984", organization_name: "Example Clinic", tax_id: "000000000",
                     address: EdiGem::Address.from(line1: "1 Example Way", city: "Los Angeles"))
subscriber = EdiGem::Subscriber.new(member_id: "ABC123", last_name: "DOE", date_of_birth: "19800101")

# An eligibility check. The payer code is the code this clearinghouse uses for the payer.
inquiry = EdiGem::Inquiry::Eligibility.new(payer_code: "12345", subscriber: subscriber,
                                           provider: provider)
response = stedi.eligibility(inquiry, archive: { name: "check-42" })
response.state            # => :complete
response.active_benefits  # => [#<EdiGem::Benefit ...>]

# A payer that needs a credential through this source. `required_credentials` names what
# sources.yml does not already declare; the inquiry's `credential:` is used over the source's.
stedi.required_credentials("100065")  # => [:portal_password], Medi-Cal's PIN
pin = EdiGem::Credential.new(provider: provider, source: :stedi, values: { portal_password: "..." })
EdiGem::Inquiry::Eligibility.new(payer_code: "100065", credential: pin, ...)

# Insurance discovery: no payer, and the date asked about is required.
discovery = EdiGem::Inquiry::Discovery.new(subscriber: subscriber, provider: provider,
                                           as_of: Date.new(2026, 9, 1))
response = stedi.discovery(discovery)
response = stedi.resolve(response.handle) while response.state == :pending

# A batch, keyed by your own identifiers.
submission = stedi.submit_batch({ "row-1" => inquiry }, name: "monthly refresh")
stedi.batch_status(submission.id).finished?
page = stedi.batch_checks(submission.id)
page = stedi.batch_checks(submission.id, page_token: page.next_page_token) while page.more?

# The same, filing each item's raw answer. Every item goes to its own object, named
# "<name>_<your identifier>", and says where it went.
page = stedi.batch_checks(submission.id, archive: { name: "batch-42" })
page.items.first.stored.response_uri   # => "s3://bucket/edi/stedi/202610/batch_check/response/..."
page.items.first.raw                   # the item as the vendor sent it, parsed
```

An identifier that is not a safe file name (or is missing) raises `ArgumentError` before anything
is written, so a page is filed whole or not at all. Reading a page again files it again, as new
objects. `raw` and the archived bodies are PHI.

A discovery's `found_plans` are the coverages it found, one per item, each read apart: its
`benefits`, its `people`, and `person`, who the payer matched (the dependent when there is one,
else the policyholder) as the payer holds them on record, address included. `coverage_on(date)`
applies the two-part test to that plan alone. A `Subscriber` takes an `address:` (an `EdiGem::Address`), which Stedi is sent.

## Dependents, and who the payer answered about

A real-time answer covers only the patient asked about. Someone on another person's policy who
the payer cannot identify on their own is asked about as a dependent: the subscriber carries the
policy's member id, and `dependent:` the patient. Stedi takes one dependent per check; a
discovery cannot take one.

```ruby
family = EdiGem::Subscriber.new(member_id: "ABC123")
child = EdiGem::Subscriber.new(first_name: "Leo", last_name: "Garcia", date_of_birth: "20100101",
                               relationship: :child) # :spouse, :child, :other_adult, or nil
inquiry = EdiGem::Inquiry::Eligibility.new(payer_code: "12345", subscriber: family,
                                           dependent: child, provider: provider)
response = stedi.eligibility(inquiry)

response.subscriber_person   # => #<EdiGem::Person subscriber ...>, the policyholder
response.dependent_people    # => [#<EdiGem::Person dependent ...>]
```

A payer may move the patient between the subscriber and dependent parts, or ignore a dependent
and answer about the subscriber, so which of the people on an answer is the one asked about is
the caller's to work out, from both parts. Names are sent as `Identity.payer_normalized` spells
them: no accents, in capitals, without the characters Stedi refuses (`~ * : ^ >`). Titles (MR,
DR, ...) are not sent, and a suffix (JR, SR, I, II, III, IV, V) goes in Stedi's `suffix`
field (X12's NM107), not the last name. A suffix the payer sends apart is read back into
`Person#last_name` (SMITH JR), so a last name means the same going and coming.
`Identity.payer_normalized_split`, `surname_words`, `suffix` and `db_normalized` are the forms a caller compares names from, and `Person#identity_corrected?`
says the payer corrected the identity it was sent (001/25). A field left nil on the Subscriber is
not sent, so a caller asks with fewer fields (no first name, or no birth date) by leaving them out.

## Response states

| state | meaning | next step |
|---|---|---|
| `complete` | coverage answered in full | record it |
| `partial` | benefit lines plus a rejection for part of the question | record what came back |
| `no_coverage` | answered, and no coverage found | record it |
| `not_identified` | the payer could not match the subscriber | correct the identifiers |
| `payer_silent` | the payer did not answer | ask again later |
| `rejected` | the request or the provider was refused | fix before asking again |
| `pending` | an asynchronous answer has not arrived | `resolve` the handle |

An unknown answer is never reported as `no_coverage`. Each `Rejection` has a `level` that says
who acts: `transport` and `envelope` (the request), `payer`, `provider` (the provider's standing
with the payer), `subscriber` and `dependent` (the person's identifiers). `retryable?` says
whether Stedi says to ask again at once: only a payer that can't answer right now (AAA 42 or 80),
and not a 42 whose follow-up is C, N or S. `reason_code` is the AAA03 as sent.
`Rejection#payer_unreached?` says the payer couldn't be reached (a 42 Stedi would ask again, an
80, or a 79, a problem connecting to it), and `Response#ask_again?` whether any of its refusals is
`retryable?`: a 79 alone is not asked again, a 42 beside one is. `#resubmission_refused?` says the
payer refused the request as sent: a 42 whose follow-up is C, N or S, which Stedi reads as a
problem with the request, for Stedi support, and not as a payer that is down.
`#our_setup_refused?` says the payer refused our setup, not the person: a 41 (our NPI, tax ID or
portal credentials) or a T4 (the payer name or ID we sent) in the payer lane, as Stedi reads them.
Its state stays `payer_silent`; the caller files it as ours. A 41 in the provider's lane is a
refusal of our provider (`rejected`).

## What payers and Stedi return, and what the gem relies on (proposed)

This is the source behind the rules: what an answer can be relied on to carry, and what is
only seen in an example or not said. It is read from Stedi's insurance discovery docs
([discovery](https://www.stedi.com/docs/healthcare/insurance-discovery),
[overview](https://www.stedi.com/docs/healthcare/insurance-discovery-overview),
[API reference](https://www.stedi.com/docs/healthcare/api-reference/post-insurance-discovery)),
read Oct 22 2026. The pages carry no version or date, so a later version may differ.
**Guarantee** means the reference says so, **example** that only an example shows it, and
**open** that neither does.

What a payer returns about a person:

- **An address:** when the subscriber is the patient, the subscriber's address is returned,
  at least the first line and the city. "ADDRESS UNKNOWN" is allowed when the payer has none
  (X12 RFI 1934). The returned address "must match the request or be a previous address", so a
  difference may be an old address. `postalCode` has no punctuation (guarantee); whether the
  address is USPS-standardized is open. That's why the first line's words and the first five
  postal digits are the parts worth comparing.
- **An SSN:** a payer must return an identifier only when it was sent and the payer used it to
  find the person (X12 RFI 2119). An SSN that wasn't sent almost never comes back, and whether
  one comes back whole, masked or at all is open. The gem does not read it.
- **A dependent:** comes in the `dependent` part, with the policyholder's `memberId` on the
  subscriber (guarantee). A payer may move the patient between the parts ("Dependents, and who
  the payer answered about", above).

How a Stedi discovery searches, and what it gives back:

- **It searches on the demographics given,** "alongside its proprietary logic". "The more
  information you provide, the more likely Stedi is to find matching coverage." Without the
  state, it reaches only large national payers, so the backend sends the room's state with every
  discovery. A full SSN is best; the last four "can help narrow down matching coverage".
- **More than one item** "doesn't necessarily mean the patient has more than one active plan":
  some national payers return every coverage on file, inactive included; dental and vision come
  back too; matching is on demographics, so an item can be someone else's; and some extra
  coverage is real (an MCO and the state's Medicaid often name each other).
- **Matching is the caller's:** "false positives are possible, so you're ultimately responsible
  for matching results to your own records." Names may vary; the birth date "must match exactly".
  The gem gives the name forms to compare from (`Identity`); the comparison is the caller's.
- **`confidence`** is `HIGH` or `REVIEW_NEEDED`, and the guide says every coverage is
  `REVIEW_NEEDED`. The gem reads it; nothing relies on it.
- **Which plan is primary** isn't said by a discovery. A coordination of benefits check does that.
- **A polled result** has no copy of the request (guarantee, by its listed fields), and is kept
  30 days. Only the archive holds what was asked.
- **Codes 5, 7 and 8** (active pending investigation; inactive pending an eligibility update;
  inactive pending investigation) are allowed on a discovery's benefit lines. Whether discovery
  answers carry them is open.

**What production discoveries returned.** 35 de-identified discovery answers, read Sep 20 2026
by the gem, counted Oct 23. Counts only, nothing about any person:

- Up to 5 plans per answer, 64 in all. UnitedHealthcare alone was 42 of them, mostly past
  coverage.
- Every plan carried an address with a ZIP. None carried an SSN, as RFI 2119 predicts for an
  SSN that wasn't sent.
- 3 plans came back in the dependent part.
- 2 answers were about two different people (names or birth dates differ within one answer).
- `confidence` was absent on every plan.
- What each request carried (an address, an SSN) isn't in the corpus.

Each open item is settled by an observed answer or by Stedi support. Until then the gem reports
what doesn't hold as `not_returned` or `not_compared`, never as a match or a difference.

## V1 reference: what the backend calls

This section is the caller contract for the calls the Samaritan backend makes. It covers
Stedi and `Source::Mock`, which is Stedi with discovery answered from code, asking a check once
unless given `payer_pauses:`. Each object's own class comment is the maintainers' reference, and
holds the reasons behind its rules.

Parts marked **(proposed)** have not been reviewed by Danny yet.
Their contract can still change.

### Failures every operation shares

Every error is an `EdiGem::Error`. `code` names it (`credential_missing`); a `Fault`'s code is
its kind (`timeout`). No message holds a value from a request or an answer.

| error | when | sent? | `retryable?` |
|---|---|---|---|
| `IdentifiersNotAccepted` | the inquiry has none of the source's `search_options` | no | none: fix the inquiry |
| `PayerNotRouted` | a check carries no payer code | no | none |
| `CredentialMissing` | the payer needs a credential (`sources.yml` `payer_credentials`) and none was given | no | none |
| `ArchiveNotConfigured` | `archive:` was asked for and the source has no archive | no | none |
| `ArgumentError` | `archive:` has no `name:` (before sending), or a batch item's name is not a safe file name (after the page is read, before any write) | no write | none |
| `Fault` | the source failed to answer, after the gem's own retries | yes | by kind, below |
| `UnreadableBody` | the source answered with success and a body that is not JSON | yes, billed | none |
| `ArchiveFailed` | the archive could not write or read a body | depends | by case, in the archive table above |

`Fault` kinds come from `Fault::KINDS` (`lib/edi_gem/fault.rb`), the one definition:

| kind | `retryable?` | meaning |
|---|---|---|
| `timeout` | true | the vendor did not answer in time |
| `unreachable` | true | the connection never established |
| `rate_limited` | true | too many requests (429) |
| `vendor_unavailable` | true | the vendor is failing, not refusing (5xx) |
| `already_in_flight` | true | an identical request is still being processed (Stedi's 409) |
| `payer_unavailable` | true | the vendor reached the payer and the payer did not answer |
| `vendor_error` | false | the vendor answered that it could not complete the request (a discovery with status `ERROR`) |
| `not_authorized` | false | our key was refused (401, 403) |
| `malformed_request` | false | the vendor rejected the request as invalid (400, 404, 422, other 4xx) |
| `unexpected` | false | a failure the gem has no row for |

A `Fault` from an HTTP status carries `status`, and `retry_after`: the vendor's `Retry-After` in
seconds, or nil. A real-time check's 400 is read first (`errors.answer_in_status` in
`data/sources.yml`, `Policy#answer_in_status?`): Stedi answers a payer it can't connect to with a
400 that holds an AAA 79, so a 400 holding an AAA is a `Response`, read as a 200's is, and one
holding none is the `malformed_request` it always was.

**Retry.** The gem retries a retryable `Fault` before raising it: 3 attempts, 0.5 s first
backoff, doubling, at most 20 s, with 25% jitter. A vendor's `Retry-After` wins over the backoff.
These are the `retry` defaults in `lib/edi_gem/data/sources.yml`, and `Policy.for` can change
them. An operation may set its own: a check retries a 429 until its two minutes end
(`retry_until_end`), and a discovery send or a batch submit cut short by our own timeout is not
sent again. A retry sends the same idempotency key. Stedi documents what a key does (kept 24 hours, a
409 while the first is in progress) for its claim and event endpoints only; its eligibility,
discovery and batch pages don't mention keys. The gem never retries an `ArchiveFailed`; the caller
decides from `retryable?`.

### `eligibility(inquiry, idempotency_key: nil, archive: nil)`

- **Inputs.** `inquiry` is an `Inquiry::Eligibility`: `payer_code` (the source's code for the
  payer, required), `subscriber`, optional `dependent` (the patient on the subscriber's policy),
  `provider`, optional `credential`. `idempotency_key` replaces the one the gem derives from the
  body. `archive:` is nil, or `{ name: "stem" }` plus a value for each placeholder the template
  leaves to the caller.
- **Outcome.** A settled `Response` (never `pending`). Read it with `checked_plan(identification:)`.
- **Effects.** One billed POST to Stedi, waited on for up to 125 s: Stedi holds a check open for
  up to 120 s and warns against cancelling sooner. When the payer can't answer right now and
  `ask_again?` holds, the gem asks again after each pause (`Source::Stedi::AskingAgain::PAUSES`,
  1, 5, 10, 20, 30 and 30 s; `payer_pauses:` on `Stedi.new` replaces them, `[]` asks once), each
  time under `"<key>-r<n>"`, as Stedi says for up to two minutes: no send, a transport retry
  included, starts once 120 s have passed since the first. Stedi doesn't bill a 42 or an 80. The
  last answer is returned. With `archive:`, each request body (credential fields
  redacted) and response body is written under feature `eligibility_check`, and
  `response.stored` says where the last went.
- **Failures.** The shared table. An `ArchiveFailed` on the write comes after the answer was
  billed; the `Response` is not returned.
- **Retry.** The gem's, above, within the same two minutes. A 429 is retried until they end, past
  `attempts`: Stedi lists a 429 as a 42, retried for up to two minutes. **(proposed)** `inquiry.idempotency_key(secret:, on:,
  clearinghouse:)` gives one key per question per caller's day, and `inquiry.fingerprint(secret:,
  clearinghouse:)` one key per question on any day (`EdiGem::RequestKey`).

### `discovery(inquiry, idempotency_key: nil, archive: nil)` and `resolve(handle, archive: nil)`

- **Inputs.** `inquiry` is an `Inquiry::Discovery`: `subscriber` (names, birth date, and
  optionally `address` and `ssn`), `provider`, and `as_of`, the day asked about (required). A
  discovery cannot take a `dependent` (`ArgumentError`). `resolve` takes the `handle` of a
  pending `Response`.
- **Outcome.** A `Response`. `pending` with a `handle` when Stedi has not finished; call
  `resolve(handle)` later. Otherwise settled: `no_coverage` when Stedi found nothing. Read it with
  `medical_plans`, and with no plan by its `state`.
- **Effects.** `discovery` is one billed POST; `resolve` is a GET. The gem sends at most one
  discovery a second (a burst of 2), with a 130 s timeout. With `archive:`, each call writes under feature `discovery`: the
  POST writes a request and a response, and a GET writes a response only (`request_uri` nil).
- **Failures.** The shared table. A discovery Stedi gave up on (status `ERROR`) raises
  `Fault` `vendor_error` after its body is written.
- **Retry.** The gem's, above, except a timeout: a send cut short by our own timeout is not sent
  again, since the first may still be running and Stedi documents no key for discovery. A poll
  (`resolve`) is a read, and is retried as by default, a timeout included. **(proposed)**
  `inquiry.idempotency_key(secret:, on:)` and
  `inquiry.fingerprint(secret:)`, as for a check. When to call `resolve` again is the caller's.

### Batch: `submit_batch`, `batch_status`, `batch_checks`, `batch_results`

- **Inputs.** `submit_batch(inquiries, name: nil, idempotency_key: nil, max_retry_hours: nil)`:
  a Hash of your identifier to `Inquiry::Eligibility` (an Array is keyed by position), up to
  10,000. The others take the batch id, and `batch_checks` and `batch_results` take `page_token:`,
  `page_size:`, `archive:` and `only:` (identifiers: the items sent under those alone are read and
  filed, so a caller that took some answers already reads only the rest).
- **Outcome.** `Batch::Submission` (`id` to keep), `Batch::Status`, `Batch::Checks` (each item's
  state) and `Batch::Answers` (each finished item's full answer as a `Response`). A nil
  `next_page_token` is the only sign the listing is complete.
- **Effects.** Each check is billed as a real-time check. With `archive:`, each item is its own
  object named `<name>_<identifier>`, under feature `batch_check` or `batch_result`. Every name is
  checked before the first write, so a page is filed whole or not at all.
- **Failures and retry.** The shared table and the gem's retry, except that a submit cut short by
  our own timeout is not sent again: Stedi doesn't say a second submit makes no second batch. Stedi
  keeps retrying a silent payer for `max_retry_hours` (8 by default, up to 24).

### `archived_discovery(uri)`

- **Inputs.** A `Stored` uri: its `response_uri`.
- **Outcome.** The kept discovery answer as a `Response`, read as it was recorded the day
  it came; it is never asked again. Its one exchange is the archive's read: a `get` of the uri, status
  200, no headers.
- **Effects.** One archive read. Nothing is sent to Stedi, and nothing is billed.
- **Failures.** `ArchiveNotConfigured` with no archive. `ArchiveFailed` when the body cannot be
  read, or the uri (nil included) is not one this archive made; `retryable?` is in the archive
  table above. `UnreadableBody` when the body is not JSON.
- **Retry.** None in the gem. A caller may read again when `retryable?` is true. **(proposed)**

### `MedicalPlan#payer_id` (proposed)

- **Input.** None. It reads the plan's `payer_code`.
- **Outcome.** Stedi's payer ID for that code (a String), or nil. nil means the payer directory
  holds no single payer that answers to the code, or the plan has no directory.
- **Effects.** The first call for a code searches Stedi's payer directory: a request, not
  billed. The source remembers the answer, nil included, for its lifetime.
- **Failures.** A failed search raises as any request does (`Fault`, `UnreadableBody`), and
  nothing is remembered. The next call searches again.
- **Retry.** The gem's, above.

### `Response`

```ruby
response.state             # => :complete
response.handle            # => nil
response.stored            # => #<struct EdiGem::Archive::Stored request_uri="s3://example-bucket/edi/stedi/202610/eligibility_check/request/check-42_20261022T150000000Z.json", response_uri="s3://example-bucket/edi/stedi/202610/eligibility_check/response/check-42_20261022T150000000Z.json", bytes=4812>
response.trace_id          # => "00000000-0000-4000-8000-000000000001"
response.application_mode  # => "test"
response.error_summary     # => nil
response.deciding_rejection&.summary  # => "AAA 62 at subscriber, follow-up C" on a refused answer
```

| field | type | values and presence |
|---|---|---|
| `state` | Symbol | one of `Response::STATES` (the "Response states" table). Always set |
| `benefits` | Array of `Benefit` | every line the payer sent; may be empty |
| `rejections` | Array of `Rejection` | may be empty |
| `people` | Array of `Person` | a check's; empty on a discovery, whose people are on each plan |
| `found_plans` | Array of `FoundPlan` | a discovery's; empty on a check |
| `handle` | String or nil | a discovery's id; nil on a check |
| `stored` | `Archive::Stored` or nil | nil when the call did not ask to archive |
| `trace_id` | String or nil | the id to quote to the vendor or payer |
| `application_mode` | String or nil | `"test"` or `"production"`, as the vendor labels it. Stedi labels every discovery `"production"` |
| `deciding_rejection` **(proposed)** | `Rejection` or nil | the refusal that decided `state`, read in the state's own order: one about our provider, then one of the request (transport or envelope); the person's when the payer can't tell who they are; the payer's (refused as sent or our setup, then unreached, then its first); then the person's that `PersonRefusal::FINDINGS` reads; else the first. Not the first one listed: a payer can list a refusal that decides nothing ahead of the one that does. nil with no rejection |
| `error_summary` **(proposed)** | String or nil | the deciding rejection in codes alone (`Rejection#summary`). nil with no rejection |

A `Rejection` carries its reason (`code`), the AAA03 as sent (`reason_code`), its lane (`level`)
and its follow-up (`followup`, AAA04, as X12's letter or Stedi's words). `summary` says it in
codes alone, "AAA 62 at subscriber, follow-up C": the AAA03 (or the codec's reason when none came),
the lane, and the follow-up as its letter. It never carries Stedi's `description` or `resolution`,
which are free text that may repeat what we sent about the person, so it is safe to store and log.

**(proposed)** Readers:

- `checked_plan(identification:)`: the check's plan, as a `CheckedPlan`. `identification` is who
  the caller reads the answer to be about: anything answering `answered_as` and `match`.
- `medical_plans`: a discovery's `MedicalPlan`s.
- `provider_standing`: what the answer says of our provider's standing with the payer.
  `:needs_provider_details` when every refusal about our provider asks for our tax ID and address
  (`Rejection#provider_details_wanted?`: an AAA 97 in any lane, or an AAA 15 in the provider's);
  `:refused` when any other refusal is about our provider (`provider_refusals`), whatever else came
  back; `:not_connected` when Stedi couldn't connect to the payer (an AAA 79) and nothing beside it
  says to ask again (`not_connected?`); `:accepted` when the payer answered for it (`complete`, `partial`, `no_coverage`, or
  `not_identified`, since the payer looked the person up for our provider); nil when it did neither
  (`payer_silent`, `pending`, or `rejected` for a reason that is not our provider).

### `Coverage` and its `Finding`

`EdiGem::Coverage.on(benefits, date)` applies Stedi's two-part test. It returns a
`Coverage::Finding`. `Response#coverage_on(date)` and each plan's `coverage_on(date)` call it.

```ruby
finding = response.coverage_on(Date.new(2026, 10, 22))
finding.status   # => :active
finding.code     # => "1"
finding.active?  # => true
EdiGem::Coverage.context("7")  # => "inactive, the payer is updating eligibility"
```

`Coverage.context(code)` says what an EB01 code adds beyond its status (5, 7 and 8, the X12
pending codes), or nil. It takes a stored code as well as a finding's.

| field | type | values and presence |
|---|---|---|
| `status` | Symbol or nil | `:active`, `:inactive`, `:non_covered`, `:cannot_process`; nil when no line about the plan decides |
| `code` | String or nil | the EB01 code of the line that decided: `"1"` to `"5"` active (5: the payer is investigating), `"6"` to `"8"` inactive (7: the payer is updating eligibility, 8: it is investigating), `"I"` non-covered, `"V"` cannot process. nil when the plan's dates or an implied plan term decided, or nothing did |

The words a record shows for a code (its "context") are the backend's, not the gem's.

The AAA codes in the person's lanes are read by one table, `PersonRefusal::FINDINGS`, which the
answer's state asks. A refusal of what we sent decides only when no line came with it; beside
lines it refused part of the question (`partial`). Two reasons there are read apart from their
neighbors: AAA 60 is `birth_date_after_day_asked` (the birth date falls after the day asked),
apart from 62 and 63's `date_out_of_range` (the day asked is outside the payer's window); and 64 is
`dependent_id_required` (the payer needs another identifier for a dependent, which Stedi says is
ours to send), apart from 72's `member_id_invalid`; and 58 is `invalid_date_of_birth` (the birth
date missing or not written YYYYMMDD, which Stedi says to send), apart from 71's
`date_of_birth_mismatch` (a birth date the payer holds differently). All three are what we sent
(`our_fault`).

### Plans: `CheckedPlan` and `MedicalPlan` (proposed)

A check's answer (`Response#checked_plan`) and each medical plan a discovery found
(`Response#medical_plans`) are read the same way (`EdiGem::AnsweredPlan`):

```ruby
plan = response.medical_plans.first
plan.payer_code                      # => "EXAMPLE1"
plan.member_id                       # => "MOCK00000002"
plan.medicaid_id                     # => nil
plan.plan_name                       # => "Example Gold PPO"
plan.coverage_on(Date.new(2026, 9, 1)).status # => :active
plan.plan_begins_on                  # => #<Date: 2026-01-01>
plan.relationship                    # => :self
```

| field | type | values and presence |
|---|---|---|
| `payer_code` | String or nil | the payer's code as the answer gives it |
| `member_id` | String or nil | the subscriber's insurance ID; a dependent is on the subscriber's |
| `medicaid_id` | String or nil | the state Medicaid ID tied to the plan |
| `plan_name`, `plan_number`, `group_number` | String or nil | as the payer names them; nil when the answer holds none |
| `coverage_on(date)` | `Coverage::Finding` | what the plan's own lines say of that day: its `status` (`:active`, `:inactive`, `:non_covered`, or nil when they say nothing; not knowing is not a denial) and `code`, the status code |
| `plan_begins_on`, `plan_ends_on` | Date or nil | the plan's own dates; nil when none, or not a real YYYYMMDD day; an end in the year 9999 (a payer's placeholder until the plan ends) is nil |
| `relationship` | Symbol or nil | `:self` or `:dependent`, as the payer said; nil when it did not say, nobody was compared, or the payer refused the person |
| `lines` | Array of `AnsweredPlan::Line` | `benefit_type`, `service_types`, `insurance_type`, `plan_name`, `in_network` (nil when the payer did not say); empty when none |

A `CheckedPlan` also has `identification`, as passed to `checked_plan`, which decides its
`relationship`. A `MedicalPlan` also has `payer_id` (above), `person` (whose
`address` is the one the payer holds) and `benefits`. Dental and vision plans are not medical
plans. A Medicaid plan another plan names as its primary payer (its `Primary Payer` related
entity, by payer code or by name, case and spacing aside) is part of that plan, not a plan of
its own.

### `Person`

Someone as the payer holds them on its answer.

```ruby
person = plan.person
person.role                # => :subscriber
person.first_name          # => "JORDAN"
person.date_of_birth       # => "19900101"
person.relationship_code   # => "18"
person.relationship        # => :self
person.address&.postal_code # => "00000"
```

| field | type | values and presence |
|---|---|---|
| `role` | Symbol | `:subscriber` or `:dependent`, the part of the answer the person came back in. Always set |
| `first_name`, `last_name`, `middle_name` | String or nil | as the payer spells them |
| `date_of_birth` | String or nil | YYYYMMDD as sent |
| `member_id` | String or nil | never set on a dependent: theirs is the subscriber's |
| `relationship_code` | String or nil | X12's: `18` the subscriber; a dependent's `01`, `19`, `20`, `21`, `39`, `40`, `53` or `G8` |
| `relationship` **(proposed)** | Symbol or nil | `:self`, `:dependent`, or nil when the payer did not say |
| `maintenance_type_code`, `maintenance_reason_code` | String or nil | `001` with `25` means the payer corrected the identity it was sent (`identity_corrected?`) |
| `address` | `Address` or nil | the one the payer holds |

### `Archive::Stored`

Where one call's bodies went: `request_uri` (String, nil for a call with no body, such as
`resolve`), `response_uri` (String) and `bytes` (Integer, both bodies). Keep the uris to read the
bodies back. They are identifiers, and the bodies are PHI.

### `Batch::Status` and `Batch::Check`

- `Batch::Status`: `id`, `name`, `state` (Stedi's string), counts (`total`, `succeeded`,
  `failed`, `in_progress`, `validated`, `validation_failed`), `max_retry_hours`, `created_at`,
  `updated_at`. `finished?` is true for `COMPLETED`, `COMPLETED_WITH_ERRORS` and
  `VALIDATION_FAILED`. **(proposed)** `progress` is `:in_progress`, `:completed`,
  `:completed_with_errors` or `:validation_failed`.
- `Batch::Check`: `state`, `result` (Stedi's string, such as `"ACTIVE"`; `active?` reads it),
  `identifier`, `payer_code`, `member_id`, `stored` (nil unless the page was archived), `raw`
  (PHI). `settled?` when Stedi finished asking; **(proposed)** `completed?` when it finished
  without error.

## The source contract

Every source subclasses `EdiGem::Source::Base`:

- `capabilities` (`{ eligibility:, discovery:, batch: }`, all false by default) and `supports?(feature)`
- `eligibility(inquiry, idempotency_key: nil, archive: nil)`
- `discovery(inquiry, idempotency_key: nil, archive: nil)` and `resolve(handle, archive: nil)`
- `submit_batch(inquiries, name: nil, idempotency_key: nil, **options)`, `batch_status(batch_id)`,
  `batch_checks(batch_id, page_token: nil, page_size: nil, archive: nil, only: nil)`,
  `batch_results(batch_id, page_token: nil, page_size: nil, archive: nil, only: nil)`
- `payers(term)` and `payer_id_for(payer_code)`, the payer directory **(proposed)**

A feature a source does not support raises `EdiGem::FeatureNotSupported`. To add a
clearinghouse, subclass `Base` (or `X12Source` for a 270/271 vendor), declare `NAME`,
`search_options` and `capabilities`, override the features it supports, add its block to
`lib/edi_gem/data/sources.yml`, add its name to `Source::CLASSES` so `Source.for` finds it, and include `it_behaves_like "a source"` in its spec. X12 sources
also take `trace:` on `eligibility` and refuse `archive:`.

## PHI

Requests and responses carry protected health information, and sources hold keys. `inspect` and
`pp` on every object holding either (a source, its connection, an S3 signature, a CORE request, a
`Subscriber`, `Benefit`, `Payload`, `Credential`, `Exchange`, `Document`, `Response` or batch
check) print names, sizes and states, never values, and error messages name fields, not values.
Where there is no real member data and no production key, a host may set `EdiGem.reveal = true`
to print them in full; it is off unless set to `true`. Archived bodies are PHI, and so is the name you file them under: control
access to the store. Never commit real payloads; spec fixtures hold synthetic values only.

## Development

```sh
bundle install
bundle exec rake        # rspec and rubocop
bundle exec rake reek   # advisory design checks
```

The suite enforces 100% line and branch coverage of `lib/`.
