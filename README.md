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
(`attempts`, `backoff`, `multiplier`, `max_delay`, `jitter`, `retry_on`); an unknown key raises
`ArgumentError`. An operation that sets its own `retry` in `sources.yml` keeps it.

A Stedi test key reaches test mode on the same host. Optional keywords: `credential:` holds the
per-payer secrets for one provider (`EdiGem::Credential.new(provider:, source: :stedi,
values: { portal_password: "..." })`), and `archive:` is where raw bodies are kept.

The archive defaults to `EdiGem::Archive.from_env`, which reads `EDI_ARCHIVE_TEMPLATE`:

- `s3://bucket/edi/$CLEARINGHOUSE/$YYYYMM/$FEATURE/$DIRECTION` writes to S3, using
  `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and optionally `AWS_SESSION_TOKEN` and `AWS_REGION`.
- `file:///var/edi/$YYYYMMDD/$FEATURE/$DIRECTION`, or a bare path, writes locally.

The template must place `$DIRECTION`. The gem fills `$CLEARINGHOUSE`, `$FEATURE`, `$DIRECTION`,
`$YYYY`, `$MM`, `$DD`, `$YYYYMM` and `$YYYYMMDD`; any other placeholder is filled from the values
you pass with each send. Nothing is archived unless a send asks for it.

`archive.fetch(uri)` reads back a body kept at a `Stored` uri, and `stedi.archived_discovery(uri)`
reads a kept discovery answer into a `Response` again without calling Stedi (see "V1 reference").

A write or read the archive cannot complete raises `EdiGem::ArchiveFailed`, as do `archived`,
`archived_discovery` and `archived_question` when the body cannot be read. **(proposed)** Its
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
else the policyholder) as the payer holds them on record, address included. `identify(asked)`
compares that person with who was asked about, and `coverage_on(date)` applies the two-part test
to that plan alone. A `Subscriber` takes an `address:` (an `EdiGem::Address`), which Stedi is sent.

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
found = response.identify({ first_name: "Leo", last_name: "Garcia", date_of_birth: "20100101" },
                          as_dependent: true)
found.person                 # who the payer answered about, or nil
found.result.outcome         # => :matched, :mismatched or :not_compared
found.result.fields          # => { first_name: :matched, last_name: :matched, date_of_birth: :differs }
found.answered_as            # => :dependent, the part of the answer the payer put them in
```

A payer may move the patient between the subscriber and dependent parts, or ignore a dependent
and answer about the subscriber, so `identify` compares the part asked about first, then the
other. `EdiGem::Identity.compare` is the comparison: names are normalized (accents, case,
punctuation, CORE 258's suffixes), a last name may be one of two, a first name may drop a second
name, and a name of at least eight characters may come back cut short. Another name, a nickname
or a different birth date differs. A payer's 001/25 (it corrected the identity it was sent)
counts its spelling of the names when the birth date matches. Names are sent as
`Identity.plain` spells them: no accents, in capitals.

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
whether the same request may succeed later.

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
  address is USPS-standardized is open. That's why `Address#compare` compares only the first
  line's words and the first five postal digits.
- **An SSN:** a payer must return an identifier only when it was sent and the payer used it to
  find the person (X12 RFI 2119). An SSN that wasn't sent almost never comes back, and whether
  one comes back whole, masked or at all is open. The gem keeps only its last four, as
  `LastFour`, which never prints its digits.
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
  The gem compares the first name, last name and birth date (`Identity.compare`), and the address
  and last four when given (`Identification#given_fields`).
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
Stedi and `Source::Mock`, which is Stedi with discovery answered from code. Each object's own
class comment is the maintainers' reference, and holds the reasons behind its rules.

Parts marked **(proposed)** are in the working tree and have not been reviewed by Danny yet.
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
seconds, or nil.

**Retry.** The gem retries a retryable `Fault` before raising it: 3 attempts, 0.5 s first
backoff, doubling, at most 20 s, with 25% jitter. A vendor's `Retry-After` wins over the backoff.
These are the `retry` defaults in `lib/edi_gem/data/sources.yml`, and `Policy.for` can change
them. A retry sends the same idempotency key, so it is the same billed question. The gem never
retries an `ArchiveFailed`; the caller decides from `retryable?`.

### `eligibility(inquiry, idempotency_key: nil, archive: nil)`

- **Inputs.** `inquiry` is an `Inquiry::Eligibility`: `payer_code` (the source's code for the
  payer, required), `subscriber`, optional `dependent` (the patient on the subscriber's policy),
  `provider`, optional `credential`. `idempotency_key` replaces the one the gem derives from the
  body. `archive:` is nil, or `{ name: "stem" }` plus a value for each placeholder the template
  leaves to the caller.
- **Outcome.** A settled `Response` (never `pending`). Read it with `identify` and
  `checked_plan`, whose `verdict` and `verdict_code` are the check's.
- **Effects.** One billed POST to Stedi. With `archive:`, the request body (credential fields
  redacted) and the response body are written under feature `eligibility_check`, and
  `response.stored` says where.
- **Failures.** The shared table. An `ArchiveFailed` on the write comes after the answer was
  billed; the `Response` is not returned.
- **Retry.** The gem's, above. **(proposed)** `inquiry.idempotency_key(secret:, on:,
  clearinghouse:)` gives one key per question per caller's day, and `inquiry.fingerprint(secret:,
  clearinghouse:)` one key per question on any day (`EdiGem::RequestKey`). Stedi remembers a key
  for 24 hours.

### `discovery(inquiry, idempotency_key: nil, archive: nil)` and `resolve(handle, archive: nil)`

- **Inputs.** `inquiry` is an `Inquiry::Discovery`: `subscriber` (names, birth date, and
  optionally `address` and `ssn`), `provider`, and `as_of`, the day asked about (required). A
  discovery cannot take a `dependent` (`ArgumentError`). `resolve` takes the `handle` of a
  pending `Response`.
- **Outcome.** A `Response`. `pending` with a `handle` when Stedi has not finished; call
  `resolve(handle)` later. Otherwise settled: `no_coverage` when Stedi found nothing. Read it with
  `medical_plans(asked:)` and `discovery_verdict(on:, plans:)`.
- **Effects.** `discovery` is one billed POST; `resolve` is a GET. The gem sends at most one
  discovery a second (a burst of 2), with a 130 s timeout. With `archive:`, each call writes under feature `discovery`: the
  POST writes a request and a response, and a GET writes a response only (`request_uri` nil).
- **Failures.** The shared table. A discovery Stedi gave up on (status `ERROR`) raises
  `Fault` `vendor_error` after its body is written.
- **Retry.** The gem's, above. **(proposed)** `inquiry.idempotency_key(secret:, on:)` and
  `inquiry.fingerprint(secret:)`, as for a check. When to call `resolve` again is the caller's.

### Batch: `submit_batch`, `batch_status`, `batch_checks`, `batch_results`

- **Inputs.** `submit_batch(inquiries, name: nil, idempotency_key: nil, max_retry_hours: nil)`:
  a Hash of your identifier to `Inquiry::Eligibility` (an Array is keyed by position), up to
  10,000. The others take the batch id, and `batch_checks` and `batch_results` take `page_token:`,
  `page_size:` and `archive:`.
- **Outcome.** `Batch::Submission` (`id` to keep), `Batch::Status`, `Batch::Checks` (each item's
  state) and `Batch::Answers` (each finished item's full answer as a `Response`). A nil
  `next_page_token` is the only sign the listing is complete.
- **Effects.** Each check is billed as a real-time check. With `archive:`, each item is its own
  object named `<name>_<identifier>`, under feature `batch_check` or `batch_result`. Every name is
  checked before the first write, so a page is filed whole or not at all.
- **Failures and retry.** The shared table and the gem's retry. Stedi keeps retrying a silent
  payer for `max_retry_hours` (8 by default, up to 24).

### `archived(uri)`, `archived_discovery(uri)` and `archived_question(uri)`

`archived` **(proposed)** is the common name for `archived_discovery`. `archived_question` is
**(proposed)**.

- **Inputs.** A `Stored` uri: `response_uri` for `archived` and `archived_discovery`,
  `request_uri` for `archived_question`.
- **Outcome.** `archived` gives the kept discovery answer as a `Response`, read as it was the day
  it came. `archived_question` gives the question the kept request asked, as an
  `Inquiry::Question`.
- **Effects.** One archive read. Nothing is sent to Stedi, and nothing is billed.
- **Failures.** `ArchiveNotConfigured` with no archive. `ArchiveFailed` when the body cannot be
  read, or the uri (nil included) is not one this archive made; `retryable?` is in the archive
  table above. `UnreadableBody` when the body is not a discovery request (`archived_question`) or
  not JSON. A source with no discovery raises `FeatureNotSupported`.
- **Retry.** None in the gem. A caller may read again when `retryable?` is true. **(proposed)**

### `keep_question(inquiry, archive:)` (proposed)

- **Inputs.** An `Inquiry::Discovery`, and `archive: { name: "stem" }` as for `discovery`.
- **Outcome.** The `request_uri` of the discovery request the inquiry would send, kept and never
  sent. `archived_question` reads it back as it reads a request that was sent. A caller asking
  again with new details compares them with an answer already paid for (`archived`), and a later
  read can do the same.
- **Effects.** One archive write, under feature `discovery_kept`, apart from the requests Stedi
  was sent. Nothing is sent to Stedi, and nothing is billed.
- **Failures.** `ArchiveNotConfigured` with no archive, and `ArgumentError` with no name. A source
  with no discovery raises `FeatureNotSupported`.

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
response.error_code        # => nil
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
| `error_code` **(proposed)** | String or nil | the first rejection's code: a reason name (`"name_mismatch"`) or the payer's raw code when the gem has no name for it. nil with no rejection |

**(proposed)** Readers:

- `identify(asked, as_dependent: false)`: an `Identification` for a check's people. `asked` is a
  hash of `first_name`, `last_name` and `date_of_birth`.
- `checked_plan(identification:)`: the check's plan, as a `CheckedPlan`, for the person
  `identification` names. Its `verdict(on:)` is a verdict name for the check on the day `on`;
  its `verdict_code(on:)` the EB01 code behind that verdict, or nil.
- `medical_plans(asked: nil)`: a discovery's `MedicalPlan`s. `asked` is the `Person::Asked`
  each plan is compared with.
- `discovery_verdict(on:, plans:)`: a verdict name for a discovery among `plans`, its
  `medical_plans`.
- `reading`: the `Verdict` for this answer's state and refusals, which reads a plan's coverage
  (`of_plan`, `code_of`, `among`). `CheckedPlan#verdict` and `#discovery_verdict` read through it.
- `provider_standing`: what the answer says of our provider's standing with the payer.
  `:refused` when any refusal is about our provider (`provider_refusals`), whatever else came
  back; `:accepted` when the payer answered for it (`complete`, `partial` or `no_coverage`); nil
  when it did neither (`payer_silent`, `not_identified`, `pending`, or `rejected` for a reason
  that is not our provider).

### Verdict names (proposed)

`EdiGem::Verdict::NAMES` lists them, so a caller can check it records every one. `CheckedPlan#verdict`
and `Response#discovery_verdict` give one of these names, the one word to record for an answer:

| name | meaning |
|---|---|
| `active` | the plan covers the person on the day asked about |
| `inactive` | the plan does not cover them that day |
| `not_covered` | the payer answered and found no coverage |
| `unanswered` | the payer did not say, or answered about someone else |
| `provider_refused` | the payer refused our provider; fix that before asking again |
| `pending` | an asynchronous answer that has not arrived |

An error is never a lapse: whatever the payer did not say is `unanswered`.

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

### `Finding`: what the answer established (proposed)

`EdiGem::Finding` is what an answer established about the person asked about, asked the way they
were asked: one name, and the code behind it. It is the meaning only. What to do with it is the
caller's, and depends on the moment (a check with the person there, a recheck without them, a
discovery). `Finding::NAMES` lists the names, so a caller can check it handles every one.

```ruby
finding = plan.finding(on: Date.new(2026, 10, 22))
finding.name      # => :covered
finding.code      # => "1"
finding.covered?  # => true
finding.to_s      # => "covered"
```

| name | meaning |
|---|---|
| `covered` | an active line (EB01 `1` to `5`) covers the person on the day |
| `not_covered` | an inactive line (`6` to `8`), not covered (`I`), the day outside the plan's dates, or an answer with no lines: not covered on this plan. They may have another |
| `someone_else` | the answer is about a person who isn't the one asked (our name and birth date comparison): the ID is real and someone's, and says nothing of our person |
| `held_differently` | the payer found the ID but holds the person under another birth date (AAA `71`, `58`) or name (`73`, `65`). Not certainly someone else |
| `not_on_this_id` | the person isn't on the payer's books under this ID: the ID invalid (`72`, `64`), not found (`75`, `67`, `77`) or more than one match (`76`, `68`). Not a denial |
| `provider_refused` | the payer won't answer our provider. Nothing about the person |
| `no_answer` | the payer was silent, couldn't process (`V`), or no line decides |
| `our_fault` | our request was refused at the transport or envelope: we didn't ask properly |
| `pending` | an asynchronous answer that hasn't arrived |

| field | type | values and presence |
|---|---|---|
| `name` | Symbol | one of `NAMES`; each has a predicate (`covered?`, `not_on_this_id?`, ...) |
| `code` | String, Symbol or nil | the EB01 code of the line that decided; for a refusal, its reason (a `Codec::REJECT_REASON` name, or the raw code the codec didn't name); nil otherwise |

Where a finding comes from:

- `CheckedPlan#finding(on:)` (`Finding.of_check`): a check's answer about the person its
  `identification` names. The answer's state decides first (pending, refused, not identified,
  silent); then an answer about someone else is `someone_else`, and otherwise the coverage on the day.
- `MedicalPlan#finding(on:)` (`Finding.of_coverage`): a plan a discovery found, always about the
  person the plan names, whoever was asked: `covered`, `not_covered` or `no_answer`. Whether that
  person is the one asked about is the plan's `identification`.

`Verdict`, which folds several of these into one word to record, reads the same answers.

**A name the payer corrected.** When the payer says it corrected the identity it was sent
(`Person#identity_corrected?`, `001` with `25`) and the birth date matched, a first or last name
that differs counts as matched. `Identity::Result#corrected` names the fields that passed only that
way (empty otherwise), so a caller can show them as corrected rather than matched.

### Plans: `CheckedPlan` and `MedicalPlan` (proposed)

A check's answer (`Response#checked_plan`) and each medical plan a discovery found
(`Response#medical_plans`) are read the same way (`EdiGem::AnsweredPlan`):

```ruby
plan = response.medical_plans(asked: question.person).first
plan.payer_code                      # => "EXAMPLE1"
plan.member_id                       # => "MOCK00000002"
plan.medicaid_id                     # => nil
plan.plan_name                       # => "Example Gold PPO"
plan.status_on(Date.new(2026, 9, 1)) # => :active
plan.plan_begins_on                  # => #<Date: 2026-01-01>
plan.relationship                    # => :self
plan.identification.match            # => :matched
```

| field | type | values and presence |
|---|---|---|
| `payer_code` | String or nil | the payer's code as the answer gives it |
| `member_id` | String or nil | the subscriber's insurance ID; a dependent is on the subscriber's |
| `medicaid_id` | String or nil | the state Medicaid ID tied to the plan |
| `plan_name`, `plan_number`, `group_number` | String or nil | as the payer names them; nil when the answer holds none |
| `status_on(date)` | Symbol | `:active`, `:inactive`, or `:unknown` when the plan's lines say neither. Not knowing is not a denial |
| `coverage_on(date)` | `Coverage::Finding` | the finding behind `status_on`; its `code` is the status code |
| `plan_begins_on`, `plan_ends_on` | Date or nil | the plan's own dates; nil when none, or not a real YYYYMMDD day |
| `relationship` | Symbol or nil | `:self` or `:dependent`, as the payer said; nil when it did not say, nobody was compared, or the payer refused the person |
| `identification` | `Identification` | who the payer answered about, compared with who was asked |
| `lines` | Array of `AnsweredPlan::Line` | `benefit_type`, `service_types`, `insurance_type`, `plan_name`, `in_network` (nil when the payer did not say); empty when none |

A `CheckedPlan` also has `verdict(on:)` and `verdict_code(on:)` (Readers, above), which weigh
who the payer answered about. A `MedicalPlan` also has `payer_id` (above), `person` (whose
`address` is the one the payer holds) and `benefits`. Dental and vision plans are not medical
plans. A Medicaid plan another plan names as its primary payer is
part of that plan, not a plan of its own.

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
| `date_of_birth` | String or nil | YYYYMMDD as sent; `born_on` gives a Date, or nil |
| `member_id` | String or nil | never set on a dependent: theirs is the subscriber's |
| `relationship_code` | String or nil | X12's: `18` the subscriber; a dependent's `01`, `19`, `20`, `21`, `39`, `40`, `53` or `G8` |
| `relationship` **(proposed)** | Symbol or nil | `:self`, `:dependent`, or nil when the payer did not say |
| `maintenance_type_code`, `maintenance_reason_code` | String or nil | `001` with `25` means the payer corrected the identity it was sent (`identity_corrected?`) |
| `address` | `Address` or nil | the one the payer holds |
| `ssn_last_four` **(proposed)** | `LastFour` or nil | compared only; it never gives its digits back |

### `Identification`

Who the payer answered about, and how they compare with who was asked. `person` and `result` (an
`Identity::Result`) are reviewed; the rest of this table is **(proposed)**.

```ruby
id = response.identify({ first_name: "Jordan", last_name: "Example", date_of_birth: "19900101" })
id.match         # => :mismatched
id.fields        # => { first_name: :matched, last_name: :matched, date_of_birth: :differs, member_id: :not_returned }
id.reason        # => :identity_mismatch
id.answered_as   # => :subscriber
id.given_fields  # => {}
```

| field | type | values and presence |
|---|---|---|
| `person` | `Person` or nil | nil when the answer named nobody |
| `match` | Symbol | `:matched`, `:mismatched` or `:not_compared`. A payer's refusal of the person wins over our comparison |
| `fields` | Hash | `first_name`, `last_name`, `date_of_birth`, each `:matched`, `:differs` or `:not_returned` (nothing to compare). A check's also has `member_id`, which only a payer's refusal can make `:differs`. A discovery's has no `member_id` key |
| `given_fields` | Hash | `address` and `ssn_last_four`, only for details the question carried; a detail it left out has no key. Each `:matched`, `:differs`, `:not_compared` (ours can't be compared) or `:not_returned` (the payer's can't). Empty on a check. They never change `match` |
| `reason` | Symbol or nil | `:date_of_birth_mismatch`, `:name_mismatch`, `:member_id_invalid` or `:not_found` from a refusal; `:identity_mismatch` from our comparison; nil when it matched or nothing was compared |
| `answered_as` | Symbol or nil | `:subscriber` or `:dependent`; nil when nobody was compared or the payer refused |

The name and birth date rules are in "Dependents, and who the payer answered about" above.
**(proposed)** The address rule (`Address#compare`) compares the first line's words and the
first five postal digits only.

### `Inquiry::Question` and `Person::Asked` (proposed)

What a discovery asked, from `Inquiry::Discovery#question` or `archived_question`:

```ruby
question = stedi.archived_question(stored.request_uri)
question.as_of                 # => #<Date: 2026-09-01>
question.person.first_name     # => "JORDAN"
question.person.date_of_birth  # => #<Date: 1990-01-01>
question.person.address        # => #<EdiGem::Address line1,postal_code> or nil
```

`as_of` is a Date and always set. `person` is a `Person::Asked`: `first_name`, `last_name`,
`date_of_birth` (a Date, or nil when the kept body's is not a real day), `address` (or nil), and
only the last four of an SSN, which it never gives back. A recovered question's names are as they
were sent: in capitals, without accents.

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
  `batch_checks(batch_id, page_token: nil, page_size: nil, archive: nil)`,
  `batch_results(batch_id, page_token: nil, page_size: nil, archive: nil)`
- `archived(response_uri)` and `archived_question(request_uri)`, which need discovery
  **(proposed)**
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
