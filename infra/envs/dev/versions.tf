terraform {
  required_version = ">= 1.9.0, < 2.0.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.14"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.1"
    }
  }

  # Remote state in the account created by infra/bootstrap. Each environment
  # gets its own key, so a mistake in dev cannot corrupt prod state.
  # use_azuread_auth avoids shared access keys entirely.
  backend "azurerm" {
    resource_group_name  = "rg-shiftboard-tfstate"
    storage_account_name = "stshiftboardtfstate01"
    container_name       = "tfstate"
    key                  = "dev/shiftboard.tfstate"
    use_azuread_auth     = true
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id

  features {
    resource_group {
      # Guards against Terraform deleting a resource group that still holds
      # resources it does not manage.
      prevent_deletion_if_contains_resources = true
    }

    key_vault {
      # dev is meant to be disposable, so let destroy actually finish.
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = true
    }
  }
}

provider "azuread" {}
