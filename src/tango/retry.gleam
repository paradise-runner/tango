import gleam/int

pub type FailureClass {
  TransientAdapter
  AgentRuntime
  Validation
  HumanRequestedChanges
  NonRecoverablePolicy
}

pub type RetryDecision {
  RetryAfter(milliseconds: Int)
  NewImplementationAttempt
  DoNotRetry
}

pub type RetryPolicy {
  RetryPolicy(base_delay_ms: Int, max_delay_ms: Int, max_attempts: Int)
}

pub fn decide(
  policy: RetryPolicy,
  failure: FailureClass,
  attempt: Int,
) -> RetryDecision {
  case failure {
    HumanRequestedChanges -> NewImplementationAttempt
    NonRecoverablePolicy -> DoNotRetry
    TransientAdapter | AgentRuntime | Validation ->
      case attempt >= policy.max_attempts {
        True -> DoNotRetry
        False -> RetryAfter(backoff_ms(policy, attempt))
      }
  }
}

pub fn backoff_ms(policy: RetryPolicy, attempt: Int) -> Int {
  let exponent = int.max(0, attempt - 1)
  let multiplier = power_of_two(exponent)
  int.min(policy.max_delay_ms, policy.base_delay_ms * multiplier)
}

fn power_of_two(exponent: Int) -> Int {
  case exponent {
    0 -> 1
    exponent -> 2 * power_of_two(exponent - 1)
  }
}
