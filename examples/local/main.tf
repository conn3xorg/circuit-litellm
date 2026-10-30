variable "port" {
  type    = number
  default = 2304
}

# Example password only. Pass your own with -var or TF_VAR_ on a real host.
variable "db_password" {
  type      = string
  default   = "correct-horse-battery"
  ephemeral = true
  sensitive = true
}

locals {
  host = { box = "127.0.0.1" }

  # Both models go to a stand-in for an OpenAI-compatible API on port 9999,
  # which CI starts. Swap in a real provider, or Ollama, to try it for real.
  stand_in = {
    model                 = "openai/stand-in"
    api_base              = "http://127.0.0.1:9999/v1"
    api_key               = "os.environ/STAND_IN_API_KEY"
    input_cost_per_token  = 0.000001
    output_cost_per_token = 0.000002
  }
}

# PostgreSQL on the same host, listening only on localhost.
module "postgres" {
  source = "github.com/conn3xorg/circuit-postgres?ref=v0.2.0"

  hosts                = local.host
  ssh_port             = var.port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  users          = ["litellm"]
  user_passwords = { litellm = var.db_password }
  databases      = { litellm = "litellm" }
}

module "litellm" {
  source = "../.."

  depends_on = [module.postgres]

  hosts                = local.host
  ssh_port             = var.port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  db_connection_uri = "postgresql://litellm:${var.db_password}@127.0.0.1:5432/litellm"

  models = [
    { model_name = "small", litellm_params = local.stand_in },
    { model_name = "large", litellm_params = local.stand_in },
  ]
  api_keys = { STAND_IN_API_KEY = "not-a-real-key" }

  default_key_budget = 1
  max_key_budget     = 10
  budget_duration    = "30d"
}
