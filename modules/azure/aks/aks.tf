data "azurerm_subnet" "this" {
  name                 = "sn-${var.environment}-${var.location_short}-${var.core_name}-${var.name}${local.aks_name_suffix}"
  virtual_network_name = "vnet-${var.environment}-${var.location_short}-${var.core_name}"
  resource_group_name  = "rg-${var.environment}-${var.location_short}-${var.core_name}"
}

data "azurerm_resource_group" "log" {
  name = "rg-${var.environment}-${var.location_short}-log"
}

data "azurerm_storage_account" "log" {
  name                = "log${var.environment}${var.location_short}${var.core_name}${var.unique_suffix}"
  resource_group_name = data.azurerm_resource_group.log.name
}

locals {
  auto_scaler_expander = var.aks_config.priority_expander_config == null ? "least-waste" : "priority"
}

# azure-container-use-rbac-permissions is ignored because the rule has not been updated in tfsec
#tfsec:ignore:azure-container-limit-authorized-ips tfsec:ignore:azure-container-logging tfsec:ignore:azure-container-use-rbac-permissions
resource "azurerm_kubernetes_cluster" "this" {
  name                = "aks-${var.environment}-${var.location_short}-${var.name}${local.aks_name_suffix}"
  location            = data.azurerm_resource_group.this.location
  resource_group_name = data.azurerm_resource_group.this.name
  dns_prefix          = "aks-${var.environment}-${var.location_short}-${var.name}${local.aks_name_suffix}"
  kubernetes_version  = var.aks_config.version
  sku_tier            = var.aks_config.production_grade ? "Standard" : "Free"
  run_command_enabled = false

  api_server_access_profile {
    authorized_ip_ranges = var.aks_authorized_ips
  }

  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  node_os_channel_upgrade = "Unmanaged"

  auto_scaler_profile {
    # Pods should not depend on local storage like EmptyDir or HostPath
    skip_nodes_with_local_storage = false
    # Selects the node pool which would result in the least amount of waste.
    # TODO: When supported we should make use of multiple expanders #499
    expander = local.auto_scaler_expander
  }

  network_profile {
    network_plugin    = "kubenet"
    network_policy    = "calico"
    load_balancer_sku = "standard"
    load_balancer_profile {
      outbound_ip_prefix_ids = [
        var.aks_public_ip_prefix_id
      ]
    }
  }

  identity {
    type = "SystemAssigned"
  }

  azure_active_directory_role_based_access_control {
    managed                = true
    admin_group_object_ids = [var.aad_groups.cluster_admin.id]
  }

  linux_profile {
    admin_username = "aksadmin"
    ssh_key {
      key_data = var.ssh_public_key
    }
  }

  storage_profile {
    file_driver_enabled         = true
    snapshot_controller_enabled = false
  }

  dynamic microsoft_defender {
    for_each = var.defender_enabled ? [] : [""]
    
    content {
      log_analytics_workspace_id = azurerm_log_analytics_workspace.xks_op.id
    }
  }

  key_vault_secrets_provider {
    secret_rotation_enabled = true
  }

  default_node_pool {
    name           = "default"
    vnet_subnet_id = data.azurerm_subnet.this.id
    zones          = var.aks_default_node_pool_zones

    orchestrator_version = var.aks_config.version
    # This is a bug in tflint
    # tflint-ignore: azurerm_kubernetes_cluster_default_node_pool_invalid_vm_size
    vm_size                      = var.aks_default_node_pool_vm_size
    os_disk_type                 = "Ephemeral"
    os_disk_size_gb              = local.vm_skus_disk_size_gb[var.aks_default_node_pool_vm_size]
    enable_auto_scaling          = false
    node_count                   = var.aks_config.production_grade ? 2 : 1
    only_critical_addons_enabled = true
  }
}

resource "azurerm_kubernetes_cluster_node_pool" "this" {
  for_each = {
    for nodePool in var.aks_config.node_pools :
    nodePool.name => nodePool
  }

  name                  = each.value.name
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  vnet_subnet_id        = data.azurerm_subnet.this.id
  zones                 = each.value.zones

  enable_auto_scaling  = true
  os_disk_type         = "Ephemeral"
  os_disk_size_gb      = local.vm_skus_disk_size_gb[each.value.vm_size]
  orchestrator_version = each.value.version
  vm_size              = each.value.vm_size
  min_count            = each.value.min_count
  max_count            = each.value.max_count
  eviction_policy      = each.value.spot_enabled ? "Delete" : null
  priority             = each.value.spot_enabled ? "Spot" : "Regular"
  spot_max_price       = each.value.spot_max_price

  node_taints = each.value.node_taints
  node_labels = merge({ "xkf.xenit.io/node-ttl" = "168h" }, each.value.node_labels, { "xkf.xenit.io/node-pool" = each.value.name })

  kubelet_config {
    pod_max_pid = 1000
  }

  dynamic "upgrade_settings" {
    # Max surge cannot be set for pool with spot instances
    for_each = each.value.spot_enabled ? [] : [""]
    content {
      max_surge = "33%"
    }
  }

  lifecycle {
    ignore_changes = [
      # Node taints will make the node pool to be re-created, hence ignore
      node_taints,
      # Node labels will make the node pool to be updated, hence ignore
      node_labels,
    ]
  }
}

resource "azurerm_log_analytics_workspace" "xks_audit" {
  name                               = "aks-${var.environment}-${var.location_short}-${var.name}${local.aks_name_suffix}-audit"
  location                           = data.azurerm_resource_group.this.location
  resource_group_name                = data.azurerm_resource_group.this.name
  sku                                = var.audit_config.analytics_workspace.sku_name
  retention_in_days                  = var.audit_config.analytics_workspace.retention_days
  daily_quota_gb                     = var.audit_config.analytics_workspace.daily_quota_gb
  internet_ingestion_enabled         = true
  internet_query_enabled             = true
  reservation_capacity_in_gb_per_day = var.audit_config.analytics_workspace.sku_name == "CapacityReservation" ? var.defender_config.log_analytics_workspace.reservation_gb : null
}

resource "azurerm_monitor_diagnostic_setting" "log_analytics_workspace_audit" {
  count                          = var.audit_config.destination_type == "AnalyticsWorkspace" ? 1 : 0
  name                           = "log-${var.environment}-${var.location_short}-${var.name}${local.aks_name_suffix}"
  target_resource_id             = azurerm_kubernetes_cluster.this.id
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.xks_audit.id
  log_analytics_destination_type = "Dedicated"

  enabled_log {
    category = "kube-audit-admin"
  }

  metric {
    category = "AllMetrics"
    enabled  = false
  }
}

resource "azurerm_monitor_diagnostic_setting" "log_storage_account_audit" {
  count              = var.audit_config.destination_type == "StorageAccount" ? 1 : 0
  name               = "log-${var.environment}-${var.location_short}-${var.name}${local.aks_name_suffix}"
  target_resource_id = azurerm_kubernetes_cluster.this.id
  storage_account_id = data.azurerm_storage_account.log.id

  enabled_log {
    category = "kube-audit-admin"
  }

  metric {
    category = "AllMetrics"
    enabled  = false
  }
}

resource "azurerm_storage_management_policy" "log_storage_account_audit_policy" {
  count              = var.audit_config.destination_type == "StorageAccount" ? 1 : 0
  storage_account_id = data.azurerm_storage_account.log.id

  rule {
    name    = "logs_kube_audit_admin"
    enabled = true
    filters {
      prefix_match = ["insights-logs-kube-audit-admin"]
      blob_types   = ["appendBlob"]
    }
    actions {
      base_blob {
        delete_after_days_since_modification_greater_than = var.aks_audit_log_retention
      }
    }
  }
}

resource "azurerm_monitor_diagnostic_setting" "log_eventhub_audit" {
  name                           = "eventhub-${var.environment}-${var.location_short}-${var.name}${local.aks_name_suffix}-audit"
  target_resource_id             = azurerm_kubernetes_cluster.this.id
  eventhub_name                  = var.log_eventhub_name
  eventhub_authorization_rule_id = var.log_eventhub_authorization_rule_id

  enabled_log {
    category = "cluster-autoscaler"
  }

  metric {
    category = "AllMetrics"
    enabled  = false
  }
}

# This is a work around to stop any update of the AKS cluster to force a recreation of the role assignments.
# The reason this works is a bit tricky, but it gets Terraform to not reload the resource group data source.
# https://github.com/hashicorp/terraform-provider-azurerm/issues/15557#issuecomment-1050654295

locals {
  node_resource_group = azurerm_kubernetes_cluster.this.node_resource_group
}

data "azurerm_resource_group" "aks" {
  name = local.node_resource_group
}

resource "azurerm_role_assignment" "aks_managed_identity_noderg_managed_identity_operator" {
  scope                = data.azurerm_resource_group.aks.id
  role_definition_name = "Managed Identity Operator"
  principal_id         = var.aad_groups.aks_managed_identity.id
}

resource "azurerm_role_assignment" "aks_managed_identity_noderg_virtual_machine_contributor" {
  scope                = data.azurerm_resource_group.aks.id
  role_definition_name = "Virtual Machine Contributor"
  principal_id         = var.aad_groups.aks_managed_identity.id
}
