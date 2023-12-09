data "google_client_config" "default" {}

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "4.51.0"
    }
  }
}

provider "google" {
  credentials = file(var.credentials_file)

  project = var.project
  region  = var.region
  zone    = var.zone
}

# configuraciones de red

resource "google_compute_network" "vpc_network" {
  name = "terraform-network"
  auto_create_subnetworks = false
}

resource "google_compute_global_address" "private_ip_address" {
  name          = "private-ip-address"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.vpc_network.id
}

resource "google_compute_subnetwork" "my_subnetwork" {
  name                     = "terraform-subnetwork"
  region                   = var.region
  network                  = "terraform-network"
  ip_cidr_range            = "10.0.0.0/26"  
  private_ip_google_access = true
}

resource "google_compute_firewall" "allow_ssh" {
  name    = "terraform-allow-ssh"
  network = "terraform-network"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
}

resource "google_compute_firewall" "allow_http" {
  name    = "terraform-allow-http"
  network = "terraform-network"

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }

  source_ranges = ["0.0.0.0/0"]
}

resource "google_compute_firewall" "allow_https" {
  name    = "terraform-allow-https"
  network = "terraform-network"

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  source_ranges = ["0.0.0.0/0"]
}

resource "google_compute_firewall" "allow_icmp" {
  name    = "terraform-allow-icmp"
  network = "terraform-network"

  allow {
    protocol = "icmp"
  }

  source_ranges = ["0.0.0.0/0"]
}

resource "google_compute_firewall" "allow_mysql" {
  name    = "terraform-allow-mysql"
  network = "terraform-network"

  allow {
    protocol = "tcp"
    ports    = ["3306"]
  }

  source_ranges = ["0.0.0.0/0"]
}

resource "google_compute_router" "router" {
  name    = "terraform-router"
  region  = var.region
  network = "terraform-network"

  bgp {
    asn = 64514
  }
}

resource "google_compute_router_nat" "nat" {
  name                               = "terraform-router-nat"
  router                             = "terraform-router"
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

resource "google_service_networking_connection" "terrafom_connection" {
  network                 = google_compute_network.vpc_network.self_link
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_address.name]
} 

# configuraciones de IP y SSL para LB del frontend

resource "google_compute_global_address" "vue_ip_lb" {
  name       = "vue-ip-lb"
}

resource "google_dns_record_set" "frontend" {
  name = "frontend.tariq-trainee.store."
  type = "A"
  ttl  = 300

  managed_zone = "tariq-zona"

  rrdatas = [google_compute_global_address.vue_ip_lb.address]
}

resource "google_compute_managed_ssl_certificate" "lb_vue_ssl" {
  name     = "vue-ssl-cert"

  managed {
    domains = [google_dns_record_set.frontend.name]
  }
}

# configuraciones bucket del frontend

resource "google_storage_bucket" "static_website_bucket" {
  name          = "terraform-frontend-bucket"
  location      = var.region
  force_destroy = true

  website {
    main_page_suffix = "index.html"
    not_found_page   = "404.html"
  }
}

resource "google_storage_bucket_acl" "public_access" {
  bucket = google_storage_bucket.static_website_bucket.name

   predefined_acl = "publicread"
}

resource "google_storage_bucket_iam_member" "member" {
  bucket = google_storage_bucket.static_website_bucket.name
  role = "roles/storage.objectViewer"
  member = "allUsers"
}

resource "google_storage_bucket_object" "static_files" {
  for_each = fileset("./dist", "**/*")

  name   = each.value
  source = "./dist/${each.value}"
  bucket = google_storage_bucket.static_website_bucket.name
}

# configuraciones de LB para el frontend

resource "google_compute_backend_bucket" "backend_bucket" {
  name        = "my-backend-bucket"
  bucket_name = google_storage_bucket.static_website_bucket.name
  
  enable_cdn = false
}

resource "google_compute_url_map" "vue_url_map" {
  name  = "vue-url-map"
  
  default_service = google_compute_backend_bucket.backend_bucket.self_link
}

resource "google_compute_url_map" "http-redirect" {
  name = "http-redirect"
  
  default_url_redirect {
    strip_query            = false
    https_redirect         = true 
  }
}

resource "google_compute_target_http_proxy" "vue_http" {
  name = "vue-http-proxy"
  url_map = google_compute_url_map.http-redirect.id
} 

resource "google_compute_target_https_proxy" "vue_lb_default" {
  name     = "vue-https-proxy"
  url_map  = google_compute_url_map.vue_url_map.id
  ssl_certificates = [
    google_compute_managed_ssl_certificate.lb_vue_ssl.name
  ]
  depends_on = [
    google_compute_managed_ssl_certificate.lb_vue_ssl
  ]
}

resource "google_compute_global_forwarding_rule" "vue_rule" {
  name       = "vue-forwarding-rule"
  target     = google_compute_target_https_proxy.vue_lb_default.id
  port_range = "443"
  ip_address = google_compute_global_address.vue_ip_lb.id
}

resource "google_compute_global_forwarding_rule" "http-redirect" {
  name       = "http-redirect"
  target     = google_compute_target_http_proxy.vue_http.id
  ip_address = google_compute_global_address.vue_ip_lb.id
  port_range = "80"
}

# repositoio para imagenes de docker

resource "google_artifact_registry_repository" "my-repo" {
  location      = var.region
  repository_id = "terraform-images"
  format        = "DOCKER"
}

# configuraciones SQL

resource "google_sql_database_instance" "instance" {
  name = "mysql-terraform"
  region = var.region
  database_version = "MYSQL_8_0"

  depends_on = [ google_service_networking_connection.terrafom_connection ]

  settings {
    tier = "db-f1-micro"
    ip_configuration {
      ipv4_enabled  = false
      private_network  =  google_compute_network.vpc_network.self_link
    }
  }

  deletion_protection  = "false"
}

resource "google_sql_database" "backend_database" {
  name     = "terraform-db-backend"
  instance = google_sql_database_instance.instance.name
}

resource "google_sql_user" "users" {
  name     = "root"
  instance = google_sql_database_instance.instance.name
  host     = "%"
  password = "12345678"
}

# configuraciones para cluster de kubernetes

resource "google_container_cluster" "primary" {
  name     = "terraform-backend-cluster"
  location = var.zone

  remove_default_node_pool = true
  initial_node_count       = 1
  network = google_compute_network.vpc_network.self_link
  subnetwork = google_compute_subnetwork.my_subnetwork.self_link
  
  ip_allocation_policy {
    
    cluster_ipv4_cidr_block = "10.2.0.0/16"
    services_ipv4_cidr_block = "10.3.0.0/20"
  } 
}

resource "google_container_node_pool" "primary_preemptible_nodes" {
  name       = "terraform-node-pool"
  location   = var.zone 
  cluster    = google_container_cluster.primary.name
  node_count = 1

  node_config {
    preemptible  = true
    machine_type = "e2-highcpu-4"
    service_account = "535797381932-compute@developer.gserviceaccount.com"
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }
}
