# frozen_string_literal: true

# A common API to healthcare clearinghouses for eligibility checks, batch checks and insurance
# discovery.
module EdiGem
  # Every error this gem raises inherits from this.
  class Error < StandardError; end

  # The inquiry carries no payer code for the source it was sent to.
  class PayerNotRouted < Error; end

  # The source does not offer the feature that was called. See Source::Base#capabilities.
  class FeatureNotSupported < Error; end

  # No schema or policy is registered under that name.
  class UnknownSchema < Error; end

  # data/sources.yml is unreadable or declares a key twice.
  class InvalidPolicy < Error; end

  # A required credential value is missing. Raised before sending: payers answer a missing
  # credential with a rejection that reads like the provider is not enrolled.
  class CredentialMissing < Error; end

  # The inquiry carries no identifier combination the source matches on. Raised before sending,
  # because the payer's answer to an under-specified inquiry is a billed rejection.
  class IdentifiersNotAccepted < Error; end

  # The source answered with something other than success. Fault inherits from this.
  class RequestFailed < Error; end

  # A send asked to archive its bodies and no archive is configured. Raised before sending, so
  # the billed answer is never received and then lost.
  class ArchiveNotConfigured < Error; end

  # The configured archive refused or could not be reached.
  class ArchiveFailed < Error; end

  # The source answered with success and a body that cannot be parsed. The message never
  # includes any part of the body.
  class UnreadableBody < Error; end
end
