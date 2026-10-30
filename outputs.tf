output "service" {
  description = "The systemd service that runs LiteLLM on each host."
  value       = "litellm.service"
}

output "image" {
  description = "The LiteLLM image the hosts run."
  value       = local.image
}

output "keys_file" {
  description = "File on each host holding the generated LITELLM_MASTER_KEY and LITELLM_SALT_KEY. Back it up: without the salt key, the credentials LiteLLM stores in its database can't be decrypted."
  value       = local.keys_file
}
