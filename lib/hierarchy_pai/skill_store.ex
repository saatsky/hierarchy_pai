defmodule HierarchyPai.SkillStore do
  @moduledoc """
  In-memory store for AI agent skills backed by ETS.

  Skills are loaded from `priv/skills/**/SKILL.md` at application start.
  Each file must have a YAML-like frontmatter block at the top:

      ---
      name: My Skill Name
      description: Short description of what this skill does.
      type: content | research | engineering | analysis
      ---

      ... skill body used verbatim as the executor system prompt ...

  Skills are keyed by their directory name (e.g. `"press-release"`).

  ## Manual sync

  Call `sync_remote/0` to fetch skill files added to the upstream GitHub
  repository at `saatsky/hierarchy_pai` that are not yet present locally
  in `priv/skills/`. New files are written to disk and inserted into ETS.

  No periodic sync is performed — this must be triggered explicitly by the user.
  """

  use GenServer
  require Logger

  @table :skill_store
  @skills_dir "priv/skills"
  @github_api_base "https://api.github.com"
  @github_repo "saatsky/hierarchy_pai"
  @github_skills_path "priv/skills"

  ## Public API

  @doc "Returns all loaded skills sorted by name."
  @spec list() :: [map()]
  def list do
    :ets.tab2list(@table)
    |> Enum.map(fn {_id, skill} -> skill end)
    |> Enum.sort_by(& &1.name)
  end

  @doc "Returns a single skill by id (directory name), or `nil` if not found."
  @spec get(String.t()) :: map() | nil
  def get(id) do
    case :ets.lookup(@table, id) do
      [{_id, skill}] -> skill
      [] -> nil
    end
  end

  @doc """
  Fetches skill folders from the upstream GitHub repository that are not
  yet in ETS. Downloads the SKILL.md for each new skill, writes it to
  `priv/skills/<name>/SKILL.md`, and loads it into ETS.

  Returns `{:ok, count}` where count is the number of new skills loaded,
  or `{:error, reason}` if the API call fails.
  """
  @spec sync_remote() :: {:ok, non_neg_integer()} | {:error, String.t()}
  def sync_remote do
    GenServer.call(__MODULE__, :sync_remote, 30_000)
  end

  ## GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init([]) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    load_local_skills()
    {:ok, %{}}
  end

  @impl true
  def handle_call(:sync_remote, _from, state) do
    result = do_sync_remote()
    {:reply, result, state}
  end

  ## Local loading

  defp load_local_skills do
    skills_path = Application.app_dir(:hierarchy_pai, @skills_dir)

    case File.ls(skills_path) do
      {:ok, entries} ->
        entries
        |> Enum.each(fn entry ->
          skill_file = Path.join([skills_path, entry, "SKILL.md"])

          if File.regular?(skill_file) do
            case load_skill_file(entry, skill_file) do
              {:ok, skill} ->
                :ets.insert(@table, {skill.id, skill})
                Logger.info("[SkillStore] Loaded skill: #{skill.id} (#{skill.name})")

              {:error, reason} ->
                Logger.warning("[SkillStore] Skipped #{skill_file}: #{reason}")
            end
          end
        end)

      {:error, reason} ->
        Logger.warning("[SkillStore] Could not read skills directory: #{inspect(reason)}")
    end
  end

  defp load_skill_file(id, path) do
    with {:ok, raw} <- File.read(path),
         {:ok, skill} <- parse_skill_md(id, raw) do
      {:ok, skill}
    else
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  @doc false
  def parse_skill_md(id, content) do
    case String.split(content, ~r/\n?---\n/, parts: 3) do
      [_, frontmatter, body] ->
        meta = parse_frontmatter(frontmatter)

        if meta["name"] do
          {:ok,
           %{
             id: id,
             name: meta["name"],
             description: meta["description"] || "",
             type: meta["type"] || "general",
             content: String.trim(body),
             source: :local
           }}
        else
          {:error, "missing 'name' in frontmatter"}
        end

      _ ->
        {:error, "invalid SKILL.md format — expected ---\\n frontmatter \\n---\\n body"}
    end
  end

  defp parse_frontmatter(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ":", parts: 2) do
        [key, value] ->
          Map.put(acc, String.trim(key), String.trim(value))

        _ ->
          acc
      end
    end)
  end

  ## Remote sync

  defp do_sync_remote do
    local_ids = MapSet.new(list(), & &1.id)

    case list_remote_skill_dirs() do
      {:ok, remote_dirs} ->
        new_dirs = Enum.reject(remote_dirs, &MapSet.member?(local_ids, &1))

        count =
          Enum.reduce(new_dirs, 0, fn dir, acc ->
            case fetch_and_save_remote_skill(dir) do
              {:ok, skill} ->
                :ets.insert(@table, {skill.id, skill})
                Logger.info("[SkillStore] Synced remote skill: #{skill.id}")
                acc + 1

              {:error, reason} ->
                Logger.warning("[SkillStore] Failed to sync #{dir}: #{reason}")
                acc
            end
          end)

        {:ok, count}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp list_remote_skill_dirs do
    url = "#{@github_api_base}/repos/#{@github_repo}/contents/#{@github_skills_path}"

    case Req.get(url, headers: [{"User-Agent", "hierarchy_pai/1.0"}]) do
      {:ok, %{status: 200, body: items}} when is_list(items) ->
        dirs =
          items
          |> Enum.filter(&(&1["type"] == "dir"))
          |> Enum.map(& &1["name"])

        {:ok, dirs}

      {:ok, %{status: 404}} ->
        {:error,
         "Skills directory not found on GitHub yet (#{@github_repo}/#{@github_skills_path}). " <>
           "Push your changes to the repository first, then try again."}

      {:ok, %{status: 403}} ->
        {:error, "GitHub API rate limit exceeded. Wait a few minutes and try again."}

      {:ok, %{status: status}} ->
        {:error, "GitHub API returned HTTP #{status}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp fetch_and_save_remote_skill(dir) do
    url =
      "#{@github_api_base}/repos/#{@github_repo}/contents/#{@github_skills_path}/#{dir}/SKILL.md"

    case Req.get(url, headers: [{"User-Agent", "hierarchy_pai/1.0"}]) do
      {:ok, %{status: 200, body: %{"content" => b64, "encoding" => "base64"}}} ->
        raw =
          b64
          |> String.replace("\n", "")
          |> Base.decode64!()

        with {:ok, skill} <- parse_skill_md(dir, raw) do
          skill_with_source = Map.put(skill, :source, :remote)
          write_skill_to_disk(dir, raw)
          {:ok, skill_with_source}
        end

      {:ok, %{status: status}} ->
        {:error, "GitHub API returned HTTP #{status} for #{dir}/SKILL.md"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp write_skill_to_disk(dir, content) do
    skills_path = Application.app_dir(:hierarchy_pai, @skills_dir)
    dir_path = Path.join(skills_path, dir)
    File.mkdir_p!(dir_path)
    File.write!(Path.join(dir_path, "SKILL.md"), content)
  end
end
