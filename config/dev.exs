import Config

config :mishka_document, MishkaDocument.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "mishka_document_dev",
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :ash, policies: [show_policy_breakdowns?: true]
