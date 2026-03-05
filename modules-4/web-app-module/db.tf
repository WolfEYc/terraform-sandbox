resource "random_password" "db" {
  length  = 16
  special = true
}

resource "aws_secretsmanager_secret" "db" {
  name = "modules-4-db-password"
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id     = aws_secretsmanager_secret.db.id
  secret_string = random_password.db.result
}

resource "aws_db_instance" "db_instance" {
  allocated_storage   = 20
  storage_type        = "standard"
  engine              = "postgres"
  engine_version      = "18.3"
  instance_class      = "db.t3.micro"
  username            = "foo"
  password            = aws_secretsmanager_secret_version.db.secret_string
  skip_final_snapshot = true
}
