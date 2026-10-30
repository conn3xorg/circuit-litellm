locals {
  image     = "ghcr.io/berriai/litellm:${var.litellm_version}@${var.image_digest}"
  etc       = "/etc/litellm"
  keys_file = "/etc/litellm/keys.env"

  # Tuples picked by index rather than conditionals, which would want both
  # branches to have the same type.
  key_defaults = merge(
    [{}, { max_budget = var.default_key_budget }][var.default_key_budget == null ? 0 : 1],
    [{}, { budget_duration = var.budget_duration }][var.budget_duration == null ? 0 : 1],
  )
  key_limits = [{}, { max_budget = var.max_key_budget }][var.max_key_budget == null ? 0 : 1]

  # Merged at the top level only: a key set in general_settings or
  # litellm_settings replaces the circuit's value for that key whole.
  config = {
    model_list = var.models
    general_settings = merge(
      {
        store_prompts_in_spend_logs = var.log_prompts
        disable_spend_logs          = !var.spend_logs
      },
      var.general_settings,
    )
    litellm_settings = merge(
      { drop_params = true },
      [{}, { default_key_generate_params = local.key_defaults }][length(local.key_defaults) == 0 ? 0 : 1],
      [{}, { upperbound_key_generate_params = local.key_limits }][length(local.key_limits) == 0 ? 0 : 1],
      var.litellm_settings,
    )
  }

  # Where the host itself reaches LiteLLM, to check it's up.
  local_host = lookup({ "0.0.0.0" = "127.0.0.1", "::" = "[::1]" }, var.listen_address, strcontains(var.listen_address, ":") ? "[${var.listen_address}]" : var.listen_address)
  # The image has Python but no curl, and some hosts have neither.
  healthy = "podman exec litellm python -c 'import urllib.request; urllib.request.urlopen(\"http://${local.local_host}:${var.port}/health/liveliness\", timeout=5)' >/dev/null 2>&1"

  config_yaml = "# Written by Conn3x. Changes here are overwritten on the next apply.\n${yamlencode(local.config)}"
}

# LITELLM_MASTER_KEY is the proxy's admin key, and LITELLM_SALT_KEY
# encrypts the provider credentials LiteLLM keeps in its database. Both are
# made on the host by the first apply and never pass through Conn3x, so
# they're in neither the plan nor state. creates keeps them from ever being
# replaced: a new salt key would leave every stored credential unreadable.
circuit "litellm" {
  hosts = var.hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "dir" {
    directory {
      path  = local.etc
      owner = "root"
      group = "root"
      mode  = "0700"
    }
  }

  # LiteLLM wants keys that start with sk-. 32 random bytes in hex after it.
  step "keys" {
    command {
      command = "umask 077 && { printf 'LITELLM_MASTER_KEY=sk-%s\\n' \"$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \\n')\" && printf 'LITELLM_SALT_KEY=sk-%s\\n' \"$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \\n')\"; } > ${local.keys_file}.new && mv ${local.keys_file}.new ${local.keys_file}"
      creates = local.keys_file
    }
  }

  # Holds no secrets: provider keys are os.environ/NAME references that the
  # proxy resolves from the env file.
  step "config" {
    file {
      path    = "${local.etc}/config.yaml"
      content = local.config_yaml
      owner   = "root"
      group   = "root"
      mode    = "0600"
    }
  }
}

# LiteLLM runs from its official image as a Quadlet unit. Everything it
# keeps, keys, teams, budgets and spend, is in PostgreSQL, so the container
# has no volume. It's on the host's network so it can reach a PostgreSQL
# that listens only on localhost, and a model server such as Ollama on the
# same host.
module "podman" {
  source = "github.com/conn3xorg/circuit-podman?ref=v0.1.0"

  depends_on = [conn3x_command.litellm__keys, conn3x_file.litellm__config]

  hosts                = var.hosts
  ssh_user             = var.ssh_user
  ssh_port             = var.ssh_port
  ssh_private_key_file = var.ssh_private_key_file
  ssh_known_hosts_file = var.ssh_known_hosts_file
  ssh_become           = var.ssh_become

  containers = {
    litellm = {
      image   = local.image
      volumes = ["${local.etc}/config.yaml:/app/config.yaml:ro,Z"]
      # Without this, every start fetches model prices from GitHub.
      environment = var.fetch_model_prices ? {} : { LITELLM_LOCAL_MODEL_COST_MAP = "True" }
      extra = [
        "Network=host",
        "EnvironmentFile=${local.keys_file}",
        "Exec=--config /app/config.yaml --host ${var.listen_address} --port ${var.port}",
        # circuit-podman restarts the container when its unit changes, so
        # the config's hash here makes a new config take effect.
        "# config.yaml sha256 ${sha256(local.config_yaml)}",
      ]
    }
  }
  secrets = {
    litellm = merge(var.api_keys, { DATABASE_URL = var.db_connection_uri })
  }
}

circuit "ready" {
  hosts = var.hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # LiteLLM migrates its database before it answers, which on a first start
  # comes after pulling a large image. unless is checked at plan time,
  # before the restart, so anything that restarts the container makes the
  # apply check again.
  step "health" {
    depends_on = [module.podman]
    command {
      command  = "for _ in $(seq 600); do ${local.healthy} && exit 0; sleep 1; done; echo 'LiteLLM did not come up in 10 minutes. See journalctl -u litellm.' >&2; exit 1"
      unless   = local.healthy
      triggers = sha256("${local.image} ${var.listen_address} ${var.port} ${local.config_yaml}")
    }
  }
}
