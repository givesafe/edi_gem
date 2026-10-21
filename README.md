# edi_gem

One Ruby API for healthcare eligibility across clearinghouses. A source sends an eligibility
check, an insurance discovery or a batch of checks, and every answer comes back as the same
objects: a `Response` with a state, `Benefit`s and `Rejection`s. Callers never parse a 271.

## Status

Version 0.1.0, private. `Source::Stedi` is the working source. `Source::OfficeAlly` and
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

# A payer that needs a credential through this source:
EdiGem::Inquiry::Eligibility.new(payer_code: "12345", required_credentials: [:portal_password], ...)

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

Discovery benefits carry the address the payer has on record: `matched_address_line1`,
`matched_address_line2`, `matched_city`, `matched_state` and `matched_postal_code`.

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

## The source contract

Every source subclasses `EdiGem::Source::Base`:

- `capabilities` (`{ eligibility:, discovery:, batch: }`, all false by default) and `supports?(feature)`
- `eligibility(inquiry, idempotency_key: nil, archive: nil)`
- `discovery(inquiry, idempotency_key: nil, archive: nil)` and `resolve(handle, archive: nil)`
- `submit_batch(inquiries, name: nil, idempotency_key: nil, **options)`, `batch_status(batch_id)`,
  `batch_checks(batch_id, page_token: nil, page_size: nil, archive: nil)`

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
