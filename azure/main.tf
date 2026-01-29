terraform {
	required_providers {
		azurerm = {
			source  = "hashicorp/azurerm"
			version = ">= 3.0.0"
		}
		tls = {
			source  = "hashicorp/tls"
			version = ">= 4.0.0"
		}
	}
}

provider "azurerm" {
	features {}

	subscription_id = var.subscription_id
	tenant_id       = var.tenant_id
	client_id       = var.client_id

	# Base64-Inhalt (PEM oder PFX)
	client_certificate = var.client_certificate_base64

	# Nur bei PFX erforderlich
	client_certificate_password = var.client_certificate_is_pfx && var.client_certificate_password != "" ? var.client_certificate_password : null

	resource_provider_registrations = "none"
}

################################
# Resource Group
################################

resource "azurerm_resource_group" "rg" {
	name     = "${var.prefix}-rg"
	location = var.location
}

################################
# Networking
################################

resource "azurerm_virtual_network" "vnet" {
	name                = "${var.prefix}-vnet"
	address_space       = ["10.0.0.0/16"]
	location            = azurerm_resource_group.rg.location
	resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_subnet" "public" {
	name                 = "public-subnet"
	resource_group_name  = azurerm_resource_group.rg.name
	virtual_network_name = azurerm_virtual_network.vnet.name
	address_prefixes     = ["10.0.1.0/24"]
}

################################
# NSG
################################

resource "azurerm_network_security_group" "web_sg" {
	name                = "${var.prefix}-web-sg"
	location            = azurerm_resource_group.rg.location
	resource_group_name = azurerm_resource_group.rg.name

	security_rule {
		name                       = "allow-http"
		priority                   = 100
		direction                  = "Inbound"
		access                     = "Allow"
		protocol                   = "Tcp"
		destination_port_range     = "80"
		source_port_range          = "*"
		source_address_prefix      = "*"
		destination_address_prefix = "*"
	}

	security_rule {
		name                       = "allow-ssh"
		priority                   = 110
		direction                  = "Inbound"
		access                     = "Allow"
		protocol                   = "Tcp"
		destination_port_range     = "22"
		source_port_range          = "*"
		source_address_prefix      = "*"
		destination_address_prefix = "*"
	}
}

################################
# Public IP + NIC
################################

resource "azurerm_public_ip" "pip" {
	name                = "${var.prefix}-pip"
	location            = azurerm_resource_group.rg.location
	resource_group_name = azurerm_resource_group.rg.name
	allocation_method   = "Static"
	sku                 = "Standard"
}

resource "azurerm_network_interface" "nic" {
	name                = "${var.prefix}-nic"
	location            = azurerm_resource_group.rg.location
	resource_group_name = azurerm_resource_group.rg.name

	ip_configuration {
		name                          = "primary"
		subnet_id                     = azurerm_subnet.public.id
		private_ip_address_allocation = "Dynamic"
		public_ip_address_id          = azurerm_public_ip.pip.id
	}
}

resource "azurerm_network_interface_security_group_association" "nic_nsg" {
	network_interface_id      = azurerm_network_interface.nic.id
	network_security_group_id = azurerm_network_security_group.web_sg.id
}

################################
# Optional: Route Table
################################

resource "azurerm_route_table" "public" {
	name                = "${var.prefix}-public-rt"
	location            = azurerm_resource_group.rg.location
	resource_group_name = azurerm_resource_group.rg.name

	route {
		name           = "default-to-internet"
		address_prefix = "0.0.0.0/0"
		next_hop_type  = "Internet"
	}
}

resource "azurerm_subnet_route_table_association" "public_assoc" {
	subnet_id      = azurerm_subnet.public.id
	route_table_id = azurerm_route_table.public.id
}

################################
# SSH Key
################################

resource "tls_private_key" "ssh" {
	algorithm = "RSA"
	rsa_bits  = 4096
}

################################
# Linux VM + cloud-init
################################

resource "azurerm_linux_virtual_machine" "web" {
	name                = "${var.prefix}-vm"
	resource_group_name = azurerm_resource_group.rg.name
	location            = azurerm_resource_group.rg.location

	size = "Standard_B2ats_v2"

	admin_username                  = "azureuser"
	disable_password_authentication = true

	network_interface_ids = [
		azurerm_network_interface.nic.id
	]

	admin_ssh_key {
		username   = "azureuser"
		public_key = tls_private_key.ssh.public_key_openssh
	}

	os_disk {
		name                 = "${var.prefix}-osdisk"
		caching              = "ReadWrite"
		storage_account_type = "Standard_LRS"
	}

	source_image_reference {
		publisher = "Canonical"
		offer     = "0001-com-ubuntu-server-jammy"
		sku       = "22_04-lts"
		version   = "latest"
	}

	custom_data = base64encode(<<-CLOUDINIT
		#cloud-config
		package_update: true
		packages:
		  - apache2
		  - php
		  - libapache2-mod-php
		  - curl

		runcmd:
		  - systemctl enable --now apache2
		  - curl -fSL -o /var/www/html/index.php https://raw.githubusercontent.com/hashicorp/learn-terramino/master/index.php
		  - chown www-data:www-data /var/www/html/index.php
		  - rm /var/www/html/index.html
		  - systemctl restart apache2
		CLOUDINIT
	)

	tags = {
		Name = "web-instance"
	}
}