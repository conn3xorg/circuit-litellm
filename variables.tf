variable "hosts" {
  type        = any
  description = "Hosts to configure: a map of names to addresses, or to host objects with an address and optional host_key, user, port, private_key_file or jump_hosts."
}

variable "ssh_user" {
  type        = string
  default     = "root"
  description = "User to log in as."
}

variable "ssh_port" {
  type        = number
  default     = 22
  description = "SSH port."
}

variable "ssh_private_key_file" {
  type        = string
  default     = null
  description = "Path to a private key. When null, Conn3x uses the SSH agent."
}

variable "ssh_known_hosts_file" {
  type        = string
  default     = null
  description = "known_hosts file to check host keys against. When null, ~/.ssh/known_hosts."
}

variable "ssh_become" {
  type        = bool
  default     = false
  description = "Run commands as root through sudo."
}


variable "litellm_version" {
  type        = string
  default     = "v1.106.6"
  description = "Tag of the ghcr.io/berriai/litellm image, such as \"v1.106.6\". Change image_digest with it."

  validation {
    condition     = can(regex("^[A-Za-z0-9_][A-Za-z0-9_.-]*$", var.litellm_version))
    error_message = "litellm_version must be an image tag, such as \"v1.106.6\"."
  }
}

variable "image_digest" {
  type        = string
  default     = "sha256:37e2dafb088a7723beb998590682957386dfc83ffea1848486f8e0e5cfac0b06"
  description = "Digest of the image for litellm_version, such as \"sha256:37e2...\". Podman pulls by the digest, so a tag that moves upstream can't change what runs."

  validation {
    condition     = can(regex("^sha256:[a-f0-9]{64}$", var.image_digest))
    error_message = "image_digest must be a sha256 digest, such as \"sha256:\" followed by 64 hex digits."
  }
}

variable "db_connection_uri" {
  type        = string
  ephemeral   = true
  sensitive   = true
  description = "PostgreSQL connection URI, such as \"postgresql://litellm:PASSWORD@127.0.0.1:5432/litellm\". It reaches the host in a root-only file and never the plan or state."

  validation {
    condition     = can(regex("^postgres(ql)?://", var.db_connection_uri)) && !strcontains(var.db_connection_uri, "\n")
    error_message = "db_connection_uri must be a postgres:// or postgresql:// URI on one line."
  }
}

variable "listen_address" {
  type        = string
  default     = "127.0.0.1"
  description = "Address LiteLLM listens on. The default keeps it on the host for a reverse proxy in front; \"0.0.0.0\" listens on every address."

  validation {
    condition     = can(cidrhost("${var.listen_address}/${strcontains(var.listen_address, ":") ? 128 : 32}", 0))
    error_message = "listen_address must be an IPv4 or IPv6 address, such as \"127.0.0.1\"."
  }
}

variable "port" {
  type        = number
  default     = 4000
  description = "Port LiteLLM listens on."

  validation {
    condition     = var.port >= 1 && var.port <= 65535 && floor(var.port) == var.port
    error_message = "port must be a whole number from 1 to 65535."
  }
}

variable "models" {
  type        = any
  default     = []
  description = "LiteLLM's model_list: the models clients can ask for, each with a model_name and litellm_params, such as [{ model_name = \"gpt-4o\", litellm_params = { model = \"openai/gpt-4o\", api_key = \"os.environ/OPENAI_API_KEY\" } }]. It's written to config.yaml as it is, so give keys as os.environ/NAME references to api_keys."

  validation {
    condition     = can(length(var.models)) && alltrue([for m in var.models : can(tostring(m.model_name)) && can(tostring(m.litellm_params.model))])
    error_message = "models must be a list of objects, each with a model_name and litellm_params with a model, such as { model_name = \"gpt-4o\", litellm_params = { model = \"openai/gpt-4o\" } }."
  }

  # Anything named like a credential would land in the plan, state and
  # config.yaml as plain text.
  validation {
    condition     = alltrue(flatten([for m in var.models : [for k, v in m.litellm_params : !can(regex("(?i)(key|secret|password|credentials|(access|session|auth)_token)$", k)) || startswith(try(tostring(v), ""), "os.environ/")]]))
    error_message = "Credentials in litellm_params, such as api_key, must be os.environ/NAME references, with the value itself in api_keys."
  }
}

variable "guardrails" {
  type        = any
  default     = []
  description = "LiteLLM's guardrails list, such as [{ guardrail_name = \"presidio-pii\", litellm_params = { guardrail = \"presidio\", mode = \"pre_call\", default_on = true } }]. It's written to config.yaml as it is, so give keys as os.environ/NAME references to api_keys."

  validation {
    condition     = can(length(var.guardrails)) && alltrue([for g in var.guardrails : can(tostring(g.guardrail_name)) && can(tostring(g.litellm_params.guardrail))])
    error_message = "guardrails must be a list of objects, each with a guardrail_name and litellm_params with a guardrail, such as { guardrail_name = \"presidio-pii\", litellm_params = { guardrail = \"presidio\", mode = \"pre_call\" } }."
  }

  # As in models: a credential here would be plain text in the plan, state
  # and config.yaml.
  validation {
    condition     = alltrue(flatten([for g in var.guardrails : [for k, v in g.litellm_params : !can(regex("(?i)(key|secret|password|credentials|(access|session|auth)_token)$", k)) || startswith(try(tostring(v), ""), "os.environ/")]]))
    error_message = "Credentials in a guardrail's litellm_params, such as api_key, must be os.environ/NAME references, with the value itself in api_keys."
  }
}

variable "langfuse_url" {
  type        = string
  default     = null
  description = "Base URL of a Langfuse 3 or later to send a trace of every model call to over OpenTelemetry, such as \"http://127.0.0.1:3000\". Put the project's LANGFUSE_PUBLIC_KEY and LANGFUSE_SECRET_KEY in api_keys. When null, nothing is sent."

  validation {
    condition     = var.langfuse_url == null || can(regex("^https?://[^/\\s]+(/.*)?$", var.langfuse_url))
    error_message = "langfuse_url must be an http:// or https:// URL, such as \"http://127.0.0.1:3000\"."
  }
}

variable "api_keys" {
  type        = map(string)
  default     = {}
  ephemeral   = true
  sensitive   = true
  nullable    = false
  description = "Provider credentials and other secret environment variables for LiteLLM, such as { OPENAI_API_KEY = \"sk-...\", ANTHROPIC_API_KEY = \"sk-ant-...\" }. Refer to each in models as os.environ/NAME. They go to a root-only env file on the host and never reach the plan or state."

  validation {
    condition     = alltrue([for k, v in var.api_keys : can(regex("^[A-Za-z_][A-Za-z0-9_]*$", k)) && !strcontains(v, "\n")])
    error_message = "api_keys maps variable names, such as OPENAI_API_KEY, to values on one line."
  }

  validation {
    condition     = length(setintersection(keys(var.api_keys), ["DATABASE_URL", "LITELLM_MASTER_KEY", "LITELLM_SALT_KEY"])) == 0
    error_message = "Set DATABASE_URL with db_connection_uri. LITELLM_MASTER_KEY and LITELLM_SALT_KEY are generated on the host."
  }

  validation {
    condition     = var.langfuse_url == null || length(setintersection(keys(var.api_keys), ["LANGFUSE_PUBLIC_KEY", "LANGFUSE_SECRET_KEY"])) == 2
    error_message = "With langfuse_url set, api_keys needs the project's LANGFUSE_PUBLIC_KEY and LANGFUSE_SECRET_KEY."
  }
}

variable "log_prompts" {
  type        = bool
  default     = false
  description = "Store each request's messages and the model's answer in LiteLLM's spend logs, in PostgreSQL, where admins can read them in the UI, and with langfuse_url, in each Langfuse trace. Off by default: the logs and traces then hold who called which model, when, with how many tokens and at what cost, but not what was said."
}

variable "spend_logs" {
  type        = bool
  default     = true
  description = "Write a row per request to LiteLLM's spend logs. Budgets and key spend are tracked either way; turning this off loses the per-request history."
}

variable "default_key_budget" {
  type        = number
  default     = null
  description = "Budget in US dollars for a virtual key created without max_budget, such as 10. When null, such keys have no budget."

  validation {
    condition     = var.default_key_budget == null || try(var.default_key_budget >= 0, false)
    error_message = "default_key_budget must be a number of dollars, 0 or more."
  }
}

variable "max_key_budget" {
  type        = number
  default     = null
  description = "Largest max_budget, in US dollars, that /key/generate accepts. A request for more is refused. When null, there's no limit."

  validation {
    condition     = var.max_key_budget == null || try(var.max_key_budget >= 0, false)
    error_message = "max_key_budget must be a number of dollars, 0 or more."
  }
}

variable "budget_duration" {
  type        = string
  default     = null
  description = "How often a new key's budget resets when the request doesn't say, such as \"30d\" or \"7d\". When null, budgets don't reset."

  validation {
    condition     = var.budget_duration == null || can(regex("^[0-9]+[smhd]$", var.budget_duration))
    error_message = "budget_duration must be a number and a unit, s, m, h or d, such as \"30d\"."
  }
}

variable "fetch_model_prices" {
  type        = bool
  default     = false
  description = "Fetch LiteLLM's model price list from GitHub each time it starts. When false, it uses the list in the image, which is as new as litellm_version."
}

variable "general_settings" {
  type        = any
  default     = {}
  description = "More of LiteLLM's general_settings, such as { allowed_routes = [\"llm_api_routes\"] }. Merged over the circuit's own at the top level. Written to the plan, state and config.yaml, so no secrets: use os.environ/NAME."

  validation {
    condition     = can(keys(var.general_settings)) && length(setintersection(keys(var.general_settings), ["master_key", "database_url"])) == 0
    error_message = "general_settings must be an object, without master_key or database_url: the master key is generated on the host, and the database comes from db_connection_uri."
  }
}

variable "litellm_settings" {
  type        = any
  default     = {}
  description = "More of LiteLLM's litellm_settings, such as { drop_params = false, success_callback = [\"prometheus\"] }. Merged over the circuit's own at the top level. Written to the plan, state and config.yaml, so no secrets."

  validation {
    condition     = can(keys(var.litellm_settings))
    error_message = "litellm_settings must be an object."
  }
}
