# One-time bootstrap: creates the storage account that holds Terraform state
# for every environment, and nothing else.
#
# Chicken-and-egg problem: state must live somewhere before Terraform can
# manage state. So this root module uses LOCAL state, is applied once by a
# human, and its own terraform.tfstate is committed to a private location or
# simply recreated with `terraform import` if lost. Everything it creates is
# idempotent, so a lost state file is an inconvenience, not a disaster.
#  cd infra
#   cd bootstrap
#   terraform init && terraform apply
#
# After this, each env uses the azurerm backend with its own state key.

terraform {
  required_version = ">= 1.9.0, < 2.0.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.14"
    }
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id

  features {
    resource_group {
      prevent_deletion_if_contains_resources = true
    }
  }
}

resource "azurerm_resource_group" "tfstate" {
  name     = var.resource_group_name
  location = var.location

  tags = {
    purpose     = "terraform-state"
    managed_by  = "terraform"
    environment = "shared"
  }
}

resource "azurerm_storage_account" "tfstate" {
  name                     = var.storage_account_name
  resource_group_name      = azurerm_resource_group.tfstate.name
  location                 = azurerm_resource_group.tfstate.location
  account_tier             = "Standard"
  account_replication_type = "GRS"
  account_kind             = "StorageV2"

  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false # backend authenticates with OIDC/Entra

  blob_properties {
    # Versioning is the recovery mechanism for a corrupted or truncated
    # state file. Without it, a bad apply can be unrecoverable.
    versioning_enabled = true

    delete_retention_policy {
      days = 30
    }

    container_delete_retention_policy {
      days = 30
    }
  }

  tags = azurerm_resource_group.tfstate.tags
}

resource "azurerm_storage_container" "tfstate" {
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.tfstate.id
  container_access_type = "private"
}

# The pipeline's service principal needs data-plane access, which the
# control-plane Contributor role does not grant when shared keys are disabled.
resource "azurerm_role_assignment" "pipeline_blob_contributor" {
  for_each = var.pipeline_principal_ids

  scope                = azurerm_storage_account.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = each.value
}

# Protects the state account from accidental deletion. Must be removed
# deliberately before any teardown of shared infrastructure.
resource "azurerm_management_lock" "tfstate" {
  count = var.enable_delete_lock ? 1 : 0

  name       = "lock-tfstate"
  scope      = azurerm_storage_account.tfstate.id
  lock_level = "CanNotDelete"
  notes      = "Terraform state for all ShiftBoard environments. Remove only for a full teardown."
}
