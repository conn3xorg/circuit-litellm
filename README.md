# circuit-litellm

A Conn3x circuit that runs [LiteLLM Proxy](https://github.com/BerriAI/litellm), the self-hosted LLM gateway, on your own hosts. Your apps and people talk to one OpenAI-compatible endpoint, and behind it sit whichever models you choose: OpenAI, Anthropic, a local Ollama, or all three. Each team or person gets a virtual key of their own, limited to the models you allow, with a budget and rate limits, and every request is logged with who made it, which model answered and what it cost.

Provider keys stay in one place, on the host. Nobody needs your OpenAI key to use GPT, and when someone leaves, you delete their virtual key instead of rotating the real one.

LiteLLM runs from its official image, `ghcr.io/berriai/litellm`, under Podman as a systemd service, pinned by tag and digest. It keeps keys, teams, budgets and spend in PostgreSQL; pair it with [circuit-postgres](https://github.com/conn3xorg/circuit-postgres) and the whole thing fits on one host, on Debian, Ubuntu, Fedora or Rocky Linux.

The two keys LiteLLM can't live without, `LITELLM_MASTER_KEY` and `LITELLM_SALT_KEY`, are made on the host by the first apply. Your provider keys reach the host through ephemeral inputs. None of them pass into your plan, your state or your CI logs.

> **Back up `/etc/litellm/keys.env`, and never change `LITELLM_SALT_KEY`.** The salt key encrypts the provider credentials LiteLLM stores in its database, such as ones added through its admin UI. A new salt key can't read them, and LiteLLM's docs are blunt that it must not change once you've added a model. The circuit never replaces it, but a rebuilt host would make a new one unless you put the old file back first. Copy it somewhere safe, away from the database backups, as soon as the first apply finishes.

## Usage

```hcl
variable "db_password" {
  type      = string
  ephemeral = true
  sensitive = true
}

variable "openai_api_key" {
  type      = string
  ephemeral = true
  sensitive = true
}

variable "anthropic_api_key" {
  type      = string
  ephemeral = true
  sensitive = true
}

module "postgres" {
  source = "github.com/conn3xorg/circuit-postgres?ref=v0.2.0"

  hosts                = { gateway = "192.168.1.50" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  users          = ["litellm"]
  user_passwords = { litellm = var.db_password }
  databases      = { litellm = "litellm" }
}

module "litellm" {
  source = "github.com/conn3xorg/circuit-litellm?ref=v0.1.0"

  depends_on = [module.postgres]

  hosts                = { gateway = "192.168.1.50" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  db_connection_uri = "postgresql://litellm:${var.db_password}@127.0.0.1:5432/litellm"

  models = [
    {
      model_name     = "gpt-4o"
      litellm_params = { model = "openai/gpt-4o", api_key = "os.environ/OPENAI_API_KEY" }
    },
    {
      model_name     = "claude-sonnet"
      litellm_params = { model = "anthropic/claude-sonnet-4-5", api_key = "os.environ/ANTHROPIC_API_KEY" }
    },
  ]
  api_keys = {
    OPENAI_API_KEY    = var.openai_api_key
    ANTHROPIC_API_KEY = var.anthropic_api_key
  }

  default_key_budget = 20
  max_key_budget     = 200
  budget_duration    = "30d"
}
```

Then run `conn3x init` and `conn3x apply` with the secrets in the environment:

```sh
export TF_VAR_db_password='...'
export TF_VAR_openai_api_key='sk-...'
export TF_VAR_anthropic_api_key='sk-ant-...'
conn3x apply
```

A second `conn3x plan` says `No changes.` Every plan needs the secrets too, since Conn3x checks the env file on the host against them. A database password with characters such as `@`, `:` or `/` has to be percent-encoded inside the URI; the simplest fix is a password of letters and digits.

`models` is LiteLLM's own [`model_list`](https://docs.litellm.ai/docs/proxy/configs), written to `config.yaml` as you give it, so anything LiteLLM accepts there works here: other providers, several deployments behind one name, `model_info`, custom prices. What it won't take is a credential in plain text. A key such as `api_key` has to be an `os.environ/NAME` reference, and the value goes in `api_keys`, which reaches the host in a root-only env file. The circuit refuses the plan otherwise, because the plain value would end up in your state.

LiteLLM listens on `127.0.0.1:4000`. Put a reverse proxy in front for TLS (see below) before anything off the host uses it.

To try it on a throwaway container first, see [examples/local](examples/local).

### Keys for teams and people

Clients never get the master key. You use it to hand out virtual keys, through LiteLLM's [key API](https://docs.litellm.ai/docs/proxy/virtual_keys). On the host, read the master key from its file and create a team, limited to the models it may use and with a budget of its own:

```sh
mk=$(sudo sed -n 's/^LITELLM_MASTER_KEY=//p' /etc/litellm/keys.env)

curl -s http://127.0.0.1:4000/team/new \
  -H "Authorization: Bearer $mk" -H 'Content-Type: application/json' \
  -d '{"team_alias": "research", "models": ["claude-sonnet"], "max_budget": 50}'
```

The answer carries a `team_id`. Then make a key for someone on that team:

```sh
curl -s http://127.0.0.1:4000/key/generate \
  -H "Authorization: Bearer $mk" -H 'Content-Type: application/json' \
  -d '{"team_id": "TEAM_ID", "key_alias": "alice-laptop"}'
```

The `key` in the answer, `sk-...`, is what Alice puts in her tools, with `http://127.0.0.1:4000` (or your proxy's address) as the OpenAI base URL. Asking for a model outside the team's list gets a `403`. A key can also be made without a team, with its own `models`, `max_budget`, `rpm_limit` and `tpm_limit`.

The master key can do anything, so treat it like a root password: keep it on the host, and use it only for the admin API. LiteLLM's admin UI is at `/ui` on the same port, for anyone who prefers a browser.

### A local model with Ollama

LiteLLM runs on the host's network, so it reaches an [Ollama](https://github.com/conn3xorg/circuit-ollama) on the same host at `127.0.0.1:11434`. Local models then sit behind the same keys, budgets and logs as the paid ones, and nothing needs to open Ollama's unauthenticated API to the network:

```hcl
module "ollama" {
  source = "github.com/conn3xorg/circuit-ollama?ref=v0.1.1"

  hosts                = { gateway = "192.168.1.50" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  models = ["qwen2.5:0.5b"]
}

module "litellm" {
  # ...as above, with module.ollama added to depends_on, and:
  models = [
    {
      model_name     = "local"
      litellm_params = { model = "ollama_chat/qwen2.5:0.5b", api_base = "http://127.0.0.1:11434" }
    },
  ]
}
```

### TLS with Caddy

LiteLLM speaks plain HTTP. [circuit-caddy](https://github.com/conn3xorg/circuit-caddy) on the same host can put a certificate in front of it:

```hcl
module "caddy" {
  source = "github.com/conn3xorg/circuit-caddy?ref=v0.2.1"

  hosts                = { gateway = "192.168.1.50" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  email = "admin@example.com"
  sites = {
    "llm.example.com" = { reverse_proxy = ["127.0.0.1:4000"] }
  }
}
```

Clients then use `https://llm.example.com` as their base URL. Keep `listen_address` at its default, so the proxy is the only way in.

## What gets logged

For every request, LiteLLM writes a row to its spend logs in PostgreSQL: which key and team made it, which model answered, when, how many tokens, what it cost, and whether it succeeded. Requests that a key isn't allowed to make are logged too, as failures. That's the record you'd want for an audit or a chargeback, and the circuit leaves it on.

What it leaves off is the conversation itself. With `log_prompts` at its default, `false`, the request, the messages and the model's answer aren't stored. Set it to `true` and LiteLLM keeps each request and answer in full, and anyone with admin access to LiteLLM, or read access to its database, can read what your people asked. That helps when you're debugging, or when a policy says you must keep it; it's also a store of everything anyone pasted into a prompt, passwords and customer data included. Decide on purpose, and tell your users which you chose.

`spend_logs = false` stops the per-request rows altogether. Each key's and team's running spend, and so budgets, still work.

### Budgets

LiteLLM's budgets are in US dollars, priced from its list of model prices. Three inputs set defaults for keys made through `/key/generate`:

- `default_key_budget`: the budget a key gets when the request doesn't name one. Without it, such keys have no limit.
- `max_key_budget`: the largest budget a request may ask for. LiteLLM refuses more with a `400`; it doesn't quietly lower it.
- `budget_duration`: how often a key's spend resets, such as `"30d"`.

Teams, people and keys can each have their own budgets on top, through the API or the UI. For anything else LiteLLM supports, such as `upperbound_key_generate_params` for rate limits, use `litellm_settings`.

### Telemetry

LiteLLM sends no telemetry when you host it yourself; its [data security page](https://docs.litellm.ai/docs/data_security) says so, and in v1.106.6 the old `--telemetry` flag does nothing. There's nothing to turn off.

The one thing it does fetch by default is its list of model prices, from GitHub, each time it starts. The circuit turns that off, with `LITELLM_LOCAL_MODEL_COST_MAP=True`, so LiteLLM prices requests from the list in the image instead and needs nothing but your providers at runtime. The list is as new as `litellm_version`: LiteLLM can't price a model released after it, and counts it as free, until you upgrade or give it `input_cost_per_token` and `output_cost_per_token` in `litellm_params`. Set `fetch_model_prices = true` for the live list.

No callbacks are set, so nothing is sent to an observability service unless you add one in `litellm_settings`.

## Why a container

LiteLLM offers a Docker image, a Helm chart, and a Python package on PyPI. This circuit uses the image:

- **It carries everything LiteLLM needs.** The image includes the Prisma toolchain and migrations for its database, so the first start sets up PostgreSQL without npm or network access. The Python package would need its own virtualenv, Prisma and a Python LiteLLM supports, on every distribution.
- **One pin, checked.** `litellm_version` and `image_digest` go into the unit together, and Podman pulls by the digest, so a tag that's re-pushed upstream can't change what your hosts run. LiteLLM signs its images with cosign too, if you'd like to verify one before you pin it.
- **Upgrades are a diff.** Change both inputs and `conn3x plan` shows the new image in the unit file. The apply restarts LiteLLM on it, and LiteLLM runs its database migrations as it starts.

The container keeps nothing of its own. Everything LiteLLM stores is in PostgreSQL, so there's no volume to back up, only the database and `keys.env`.

It uses the host's network rather than a published port. That way it reaches a PostgreSQL and an Ollama that listen only on localhost, which is how circuit-postgres and circuit-ollama start out, and `listen_address` is a real address on the host.

The image used to come in two flavours, `litellm` and `litellm-database`. LiteLLM now ships the database tooling in `ghcr.io/berriai/litellm` itself and recommends it for new deployments, so that's the one pinned here.

## What it does

On each host, in order:

1. Creates `/etc/litellm`, mode `0700`, owned by root.
2. If `/etc/litellm/keys.env` doesn't exist, writes it, mode `0600`: `LITELLM_MASTER_KEY` and `LITELLM_SALT_KEY`, each `sk-` and 32 random bytes from `/dev/urandom` in hex. Once the file exists the circuit never touches it again.
3. Writes `/etc/litellm/config.yaml`, mode `0600`, from `models`, `general_settings`, `litellm_settings` and the logging and budget inputs. It holds no secrets.
4. Through [circuit-podman](https://github.com/conn3xorg/circuit-podman) v0.1.0, installs Podman and runs `ghcr.io/berriai/litellm:VERSION@DIGEST` as `litellm.service`: a Quadlet unit on the host network that reads `keys.env`, mounts `config.yaml` read-only, and listens on `listen_address` and `port`. `db_connection_uri` and `api_keys` go to `/etc/containers/env/litellm.env`, mode `0600`, written from ephemeral values so they never reach the plan or state.
5. Waits up to ten minutes for `/health/liveliness` to answer. On a first start LiteLLM pulls its image and migrates the database before it does.

A change to the config, the image or the address restarts LiteLLM, and the apply waits until it answers again, which took under a minute in testing.

### Moving an existing instance

To bring a LiteLLM you already run under this circuit, put its keys in `/etc/litellm/keys.env`, mode `0600`, before the first apply:

```sh
LITELLM_MASTER_KEY=sk-...
LITELLM_SALT_KEY=...
```

The circuit sees the file and keeps it. Point `db_connection_uri` at the existing database. You can change the master key later by editing that line and restarting `litellm.service`; never the salt key.

### What it doesn't do

- It doesn't set up TLS or a reverse proxy. LiteLLM speaks plain HTTP on `listen_address`.
- It doesn't open a port in a firewall. With the default `listen_address`, nothing outside the host can reach LiteLLM anyway.
- It doesn't create teams, users or keys. That's LiteLLM's API or UI, with the master key.
- It doesn't set up Redis. One LiteLLM on one host doesn't need it; several behind a load balancer do, to share rate limits and budgets.
- It doesn't back anything up. Back up PostgreSQL (see [circuit-restic](https://github.com/conn3xorg/circuit-restic)) and `keys.env`, separately.
- Models added through the admin UI are stored in the database, not in `config.yaml`, and the circuit doesn't manage them.
- Deleting the module leaves Podman, the container and `/etc/litellm` in place.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `hosts` | any | Required | Hosts to configure, by name. Each value is an address, such as `"192.168.1.50"`, or a host object such as `{ address = "192.168.1.50", host_key = "ssh-ed25519 AAAA..." }`. A host object can also set `user`, `port`, `private_key_file` and `jump_hosts`. The two forms can be mixed. |
| `ssh_user` | string | `"root"` | User to log in as. |
| `ssh_port` | number | `22` | SSH port. |
| `ssh_private_key_file` | string | `null` | Path to a private key. When null, Conn3x uses the SSH agent. |
| `ssh_known_hosts_file` | string | `null` | known_hosts file to check host keys against. When null, `~/.ssh/known_hosts`. Not used for a host object with `host_key`. |
| `ssh_become` | bool | `false` | Run commands as root through sudo. Set it when `ssh_user` isn't root. |
| `db_connection_uri` | string | Required | PostgreSQL connection URI, such as `"postgresql://litellm:PASSWORD@127.0.0.1:5432/litellm"`. Ephemeral and sensitive: it reaches the host's env file but never the plan or state. |
| `models` | any | `[]` | LiteLLM's `model_list`: a list of `{ model_name, litellm_params }` objects. Credentials in `litellm_params` must be `os.environ/NAME` references to `api_keys`. |
| `api_keys` | map(string) | `{}` | Provider credentials and other secret environment variables, such as `OPENAI_API_KEY`. Ephemeral and sensitive: they go to the env file and never the plan or state. `DATABASE_URL` and the two generated keys aren't allowed here. |
| `log_prompts` | bool | `false` | Store each request and answer in the spend logs. See [What gets logged](#what-gets-logged). |
| `spend_logs` | bool | `true` | Write a spend log row per request. |
| `default_key_budget` | number | `null` | Budget in US dollars for a key made without one. |
| `max_key_budget` | number | `null` | Largest budget `/key/generate` accepts. |
| `budget_duration` | string | `null` | How often a new key's budget resets, such as `"30d"`. |
| `fetch_model_prices` | bool | `false` | Fetch LiteLLM's model prices from GitHub at each start, rather than use the list in the image. |
| `general_settings` | any | `{}` | More of LiteLLM's [`general_settings`](https://docs.litellm.ai/docs/proxy/config_settings), merged over the circuit's at the top level. Not for secrets: it's in the plan and state. `master_key` and `database_url` aren't allowed. |
| `litellm_settings` | any | `{}` | More of LiteLLM's `litellm_settings`, merged over the circuit's at the top level, such as `{ drop_params = false }`. The circuit sets `drop_params = true`, so a parameter a provider doesn't support is dropped instead of failing the request. |
| `litellm_version` | string | `"v1.106.6"` | Tag of `ghcr.io/berriai/litellm`. Change `image_digest` with it. |
| `image_digest` | string | `"sha256:37e2dafb..."` | Digest of the image for `litellm_version`. Podman pulls by the digest. Find it with `skopeo inspect docker://ghcr.io/berriai/litellm:TAG` or on the [package page](https://github.com/BerriAI/litellm/pkgs/container/litellm). |
| `listen_address` | string | `"127.0.0.1"` | Address LiteLLM listens on. `"0.0.0.0"` listens on every address. |
| `port` | number | `4000` | Port LiteLLM listens on. |

## Outputs

| Name | Description |
| --- | --- |
| `service` | The systemd service that runs LiteLLM, `litellm.service`. |
| `image` | The image the hosts run, with its tag and digest. |
| `keys_file` | `/etc/litellm/keys.env`, the file to back up. |

## Requirements

Requires Conn3x v0.6.9 or later and systemd on each host. The image is built for amd64 and arm64. Each host needs to reach its package mirror, GitHub's container registry and your model providers, and a PostgreSQL. `conn3x init` fetches circuit-podman from GitHub.

LiteLLM used about 620 MB of memory in testing. With PostgreSQL beside it, it ran on 2 GB.

## Tested on

Rocky Linux 10, Fedora 45, Ubuntu 24.04 and Debian 13. CI applies [examples/local](examples/local) to each on amd64, with circuit-postgres on the same host, and checks that the second plan has no changes. It then runs a stand-in for an OpenAI-compatible provider, so no real API key is involved, and checks that `/health/liveliness` answers, that `/key/generate` refuses a wrong master key and a budget over `max_key_budget`, and that a key made for one model can use it, through the provider key that came in by `api_keys`, and gets a `403` for the other. The request has to show up in the spend logs in PostgreSQL with a price and without its content. After a restart, the same key works again, which needs the database and both generated keys unchanged. The same checks passed by hand on arm64 containers of all four.

They passed by hand on a Rocky Linux 10 droplet with 2 GB of memory and SELinux enforcing, too. An Ubuntu 24.04 droplet with 4 GB ran circuit-ollama beside it with `smollm2:135m`, and a team key limited to that model got an answer from it through LiteLLM. On both, port 4000 didn't answer from outside. After each of two reboots LiteLLM came back on its own, the second plan was clean, the Ubuntu team key from before still worked, and the CI checks passed again on Rocky. The Rocky audit log had no denials. Turning `log_prompts` on stored the next request and answer in the spend logs; turning it off restarted LiteLLM, and the apply waited until it answered.

Upgrading from one `litellm_version` to the next hasn't been tried yet.

## License

MPL-2.0. See [LICENSE](LICENSE). LiteLLM itself is under the MIT license, apart from its `enterprise` directory.
