terraform {
  required_providers {
    ovh = {
      source  = "ovh/ovh"
      version = "~> 0.22.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.3.2"
    }
    harbor = {
      source  = "BESTSELLER/harbor"
      version = "~> 3.0"
    }
  }
  # store state on gcs, like other clusters
  backend "s3" {
    bucket                      = "tf-state-ovh"
    key                         = "terraform.tfstate"
    region                      = "gra"
    endpoint                    = "s3.gra.io.cloud.ovh.net"
    skip_credentials_validation = true
    skip_region_validation      = true
  }
}

provider "ovh" {
  endpoint = "ovh-eu"
  # credentials loaded via source ../secrets/ovh-creds.sh
}

locals {
  service_name = "b309c78177f1458187add722e8db8dc2"
  cluster_name = "ovh2"
  # GRA9 is colocated with registry
  region = "GRA9"
}

# create a private network for our cluster
resource "ovh_cloud_project_network_private" "network" {
  service_name = local.service_name
  name         = local.cluster_name
  regions      = [local.region]
}

resource "ovh_cloud_project_network_private_subnet" "subnet" {
  service_name = local.service_name
  network_id   = ovh_cloud_project_network_private.network.id

  region  = local.region
  start   = "10.0.0.100"
  end     = "10.0.0.254"
  network = "10.0.0.0/24"
  dhcp    = true
}

resource "ovh_cloud_project_kube" "cluster" {
  service_name = local.service_name
  name         = local.cluster_name
  region       = local.region
  version      = "1.24"
  # make sure we wait for the subnet to exist
  depends_on = [ovh_cloud_project_network_private_subnet.subnet]

  # private_network_id is an openstackid for some reason?
  private_network_id = tolist(ovh_cloud_project_network_private.network.regions_attributes)[0].openstackid

  customization {
    apiserver {
      admissionplugins {
        enabled = ["NodeRestriction"]
        # disable AlwaysPullImages, which causes problems
        disabled = ["AlwaysPullImages"]
      }
    }
  }
  update_policy = "MINIMAL_DOWNTIME"
}

# ovh node flavors: https://www.ovhcloud.com/en/public-cloud/prices/

resource "ovh_cloud_project_kube_nodepool" "core" {
  service_name = local.service_name
  kube_id      = ovh_cloud_project_kube.cluster.id
  name         = "core-202211"
  # b2-15 is 4 core, 15GB
  flavor_name = "b2-15"
  max_nodes   = 3
  min_nodes   = 1
  autoscale   = true
  template {
    metadata {
      labels = {
        "mybinder.org/pool-type" = "core"
      }
    }
  }
  lifecycle {
    ignore_changes = [
      # don't interfere with autoscaling
      desired_nodes
    ]
  }
}

resource "ovh_cloud_project_kube_nodepool" "user-a" {
  service_name = local.service_name
  kube_id      = ovh_cloud_project_kube.cluster.id
  name         = "user-202211a"
  # r2-120 is 8 core, 120GB
  flavor_name = "r2-120"
  max_nodes   = 6
  min_nodes   = 1
  autoscale   = true
  template {
    metadata {
      labels = {
        "mybinder.org/pool-type" = "users"
      }
    }
  }
  lifecycle {
    ignore_changes = [
      # don't interfere with autoscaling
      desired_nodes
    ]
  }
}

# outputs

output "kubeconfig" {
  value       = ovh_cloud_project_kube.cluster.kubeconfig
  sensitive   = true
  description = <<EOF
    # save output with:
    export KUBECONFIG=$PWD/../../secrets/ovh2-kubeconfig.yml
    terraform output -raw kubeconfig > $KUBECONFIG
    chmod 600 $KUBECONFIG
    kubectl config rename-context kubernetes-admin@ovh2 ovh2
    kubectl config use-context ovh2
    EOF
}

# registry

data "ovh_cloud_project_capabilities_containerregistry_filter" "registry_plan" {
  service_name = local.service_name
  # SMALL is 200GB (too small)
  # MEDIUM is 600GB
  # LARGE is 5TiB
  plan_name = "LARGE"
  region    = "GRA"
}

resource "ovh_cloud_project_containerregistry" "registry" {
  service_name = local.service_name
  plan_id      = data.ovh_cloud_project_capabilities_containerregistry_filter.registry_plan.id
  region       = data.ovh_cloud_project_capabilities_containerregistry_filter.registry_plan.region
  name         = "mybinder-ovh"
}

# admin user (needed for harbor provider)
resource "ovh_cloud_project_containerregistry_user" "admin" {
  service_name = ovh_cloud_project_containerregistry.registry.service_name
  registry_id  = ovh_cloud_project_containerregistry.registry.id
  email        = "mybinder-admin@mybinder.org"
  login        = "mybinder-admin"
}


# now configure the registry via harbor itself
provider "harbor" {
  url      = ovh_cloud_project_containerregistry.registry.url
  username = ovh_cloud_project_containerregistry_user.admin.login
  password = ovh_cloud_project_containerregistry_user.admin.password
}

# user builds go in mybinder-builds
# these are separate for easier separation of retention policies
resource "harbor_project" "mybinder-builds" {
  name = "mybinder-builds"
}

# we should be able to use robot accounts
# after an update to Harbor and the harbor provider
resource "harbor_robot_account" "builder" {
  name        = "builder"
  description = "BinderHub builder: push new user images"
  level       = "project"
  permissions {
    access {
      action   = "push"
      resource = "repository"
    }
    access {
      action   = "pull"
      resource = "repository"
    }
    kind      = "project"
    namespace = harbor_project.mybinder-builds.name
  }
}

resource "harbor_robot_account" "user-puller" {
  name        = "user-puller"
  description = "Pull access to user images"
  level       = "project"
  permissions {
    access {
      action   = "pull"
      resource = "repository"
    }
    kind      = "project"
    namespace = harbor_project.mybinder-builds.name
  }
}

resource "random_password" "builder" {
  length  = 16
  special = true
}

resource "random_password" "user-puller" {
  length  = 16
  special = true
}

# TODO: delete after migrating to robot accounts
resource "harbor_user" "builder" {
  username  = "mybinder-builder"
  password  = random_password.builder.result
  full_name = "MyBinder Builder"
  email     = "builder@mybinder.org"
}

resource "harbor_user" "user-puller" {
  username  = "mybinder-puller"
  password  = random_password.user-puller.result
  full_name = "MyBinder Puller"
  email     = "puller@mybinder.org"
}

resource "harbor_project_member_user" "builder" {
  project_id = harbor_project.mybinder-builds.id
  user_name  = harbor_user.builder.username
  role       = "developer"
}

resource "harbor_project_member_user" "user-puller" {
  project_id = harbor_project.mybinder-builds.id
  user_name  = harbor_user.user-puller.username
  role       = "limitedguest"
}

# END delete

# retention policies created by hand
# OVH harbor is too old for terraform provider (2.0.1, need 2.2)
resource "harbor_retention_policy" "builds" {
  scope    = harbor_project.mybinder-builds.id
  schedule = "Weekly"
  rule {
    repo_matching        = "**"
    tag_matching         = "**"
    most_recently_pulled = 1
    untagged_artifacts   = false
  }
  rule {
    repo_matching          = "**"
    tag_matching           = "**"
    n_days_since_last_pull = 30
    untagged_artifacts     = false
  }
  rule {
    repo_matching          = "**"
    tag_matching           = "**"
    n_days_since_last_push = 7
    untagged_artifacts     = false
  }
}

resource "harbor_garbage_collection" "gc" {
  schedule        = "Weekly"
  delete_untagged = true
}

# registry outputs

output "registry_url" {
  value = ovh_cloud_project_containerregistry.registry.url
}

output "registry_admin_login" {
  value     = ovh_cloud_project_containerregistry_user.admin.login
  sensitive = true
}

output "registry_admin_password" {
  value     = ovh_cloud_project_containerregistry_user.admin.password
  sensitive = true
}

output "registry_builder_token" {
  value     = harbor_robot_account.builder.secret
  sensitive = true
}

output "registry_user_puller_token" {
  value     = harbor_robot_account.user-puller.secret
  sensitive = true
}
