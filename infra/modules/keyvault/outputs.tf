output "id" {
  value = azurerm_key_vault.this.id
}

output "name" {
  value = azurerm_key_vault.this.name
}

output "vault_uri" {
  description = "Used by External Secrets Operator as the SecretStore vaultUrl."
  value       = azurerm_key_vault.this.vault_uri
}
