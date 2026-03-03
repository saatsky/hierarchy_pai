[
  import_deps: [:ash_ai, :ash_admin, :ash_json_api, :ash_phoenix, :ash, :reactor, :phoenix],
  plugins: [Spark.Formatter, Phoenix.LiveView.HTMLFormatter],
  inputs: ["*.{heex,ex,exs}", "{config,lib,test}/**/*.{heex,ex,exs}"]
]
