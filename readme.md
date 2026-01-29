# Terraform terramino demo on Azure


### Commands to execute

terraform init

terraform plan -var-file=terraform.tfvars

terraform apply --auto-approve -var-file=terraform.tfvars

terraform destroy --auto-approve

### In case of ssh to vm
terraform output -raw ssh_private_key > private_key.pem




