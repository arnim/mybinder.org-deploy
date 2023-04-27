terraform {
  backend "gcs" {
    bucket = "tf-state-binder-prod"
    prefix = "terraform/state"
  }
}

provider "google" {
  project = "binderhub-288415"
  region  = "us-central1"
  zone    = "us-central1-a"
}

locals {
  gke_version        = "1.23.16-gke.1400"
  location           = "us-central1" # for regional clusters
  federation_members = ["gesis", "ovh"]
}

module "mybinder" {
  source = "../modules/mybinder"

  name               = "prod"
  gke_master_version = local.gke_version
  gke_location       = local.location # regional cluster for better upgrades

  sql_tier = "db-n1-standard-1"

  federation_members = ["gesis", "ovh"]
}

# define node pools here, too hard to encode with variables
# note: when upgrading a node pool:
# 1. copy the pool to be upgraded and change the name
# 2. make the planned changes
# 3. deploy them with terraform
# 4. drain old pools (takes a while for user pools)
# 5. once drained, remove old pool(s) here
# 6. deploy again to remove old pool

resource "google_container_node_pool" "core" {
  name     = "core-2023-04"
  cluster  = module.mybinder.cluster_name
  location = local.location # location of *cluster*
  # node_locations lets us specify a single-zone regional cluster:
  node_locations = ["${local.location}-a"]

  initial_node_count = 1
  autoscaling {
    min_node_count = 1
    max_node_count = 4
  }

  version = local.gke_version

  node_config {
    machine_type = "e2-highmem-2"
    disk_size_gb = 64
    disk_type    = "pd-balanced"

    labels = {
      "mybinder.org/pool-type" = "core"
    }
    # https://www.terraform.io/docs/providers/google/r/container_cluster.html#oauth_scopes-1
    oauth_scopes = [
      "storage-ro",
      "logging-write",
      "monitoring",
    ]

    metadata = {
      disable-legacy-endpoints = "true"
    }
  }

  # do not recreate pools that have been auto-upgraded

  lifecycle {
    ignore_changes = [
      version,
      initial_node_count,
    ]
  }
}

resource "google_container_node_pool" "core1" {
  name     = "core-202201"
  cluster  = module.mybinder.cluster_name
  location = local.location # location of *cluster*
  # node_locations lets us specify a single-zone regional cluster:
  node_locations = ["${local.location}-a"]

  initial_node_count = 1
  autoscaling {
    min_node_count = 1
    max_node_count = 4
  }

  version = local.gke_version

  node_config {
    machine_type = "n1-highmem-4"
    disk_size_gb = 250
    disk_type    = "pd-balanced"

    labels = {
      "mybinder.org/pool-type" = "core"
    }
    # https://www.terraform.io/docs/providers/google/r/container_cluster.html#oauth_scopes-1
    oauth_scopes = [
      "storage-ro",
      "logging-write",
      "monitoring",
    ]

    metadata = {
      disable-legacy-endpoints = "true"
    }
  }

  # do not recreate pools that have been auto-upgraded

  lifecycle {
    ignore_changes = [
      version,
      initial_node_count,
    ]
  }
}

resource "google_container_node_pool" "user1" {
  name     = "user-202201"
  cluster  = module.mybinder.cluster_name
  location = local.location # location of *cluster*
  # node_locations lets us specify a single-zone regional cluster:
  node_locations = ["${local.location}-a"]
  version        = local.gke_version

  initial_node_count = 2
  autoscaling {
    min_node_count = 2
    max_node_count = 12
  }

  node_config {
    machine_type    = "n1-highmem-8"
    disk_size_gb    = 800
    disk_type       = "pd-balanced"
    local_ssd_count = 1

    labels = {
      "mybinder.org/pool-type" = "users"
    }
    # https://www.terraform.io/docs/providers/google/r/container_cluster.html#oauth_scopes-1
    oauth_scopes = [
      "storage-ro",
      "logging-write",
      "monitoring",
    ]

    metadata = {
      disable-legacy-endpoints = "true"
    }
  }

  # do not recreate pools that have been auto-upgraded

  lifecycle {
    ignore_changes = [
      version,
      initial_node_count,
    ]
  }
}

# other prod-only resources, not required for both prod and staging,
# for example billing bucket
resource "google_storage_bucket" "billing" {
  name                        = "binder-billing-archive"
  location                    = "US"
  uniform_bucket_level_access = true
}


# outputs: things we want to be able to see and/or save to files
# e.g. credentials for deployment / event logging

# output "public_ip" {
#   value       = module.mybinder.public_ip
#   description = "store in ingress-nginx.controller.service.loadBalancerIP"
# }

output "matomo_password" {
  value     = module.mybinder.matomo_password
  sensitive = true
}

output "private_keys" {
  value       = module.mybinder.private_keys
  description = "GCP service account keys"
  sensitive   = true
}

output "events_archiver_keys" {
  value     = module.mybinder.events_archiver_keys
  sensitive = true
}
