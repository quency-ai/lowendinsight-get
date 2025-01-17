# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule LowendinsightGet.GithubTrending do
  require Logger
  require HTTPoison.Retry

  @type language() :: String.t()

  def process_languages() do
    Application.get_env(:lowendinsight_get, :languages)
    |> Enum.each(fn language -> LowendinsightGet.GithubTrending.analyze(language) end)
  end


  @spec analyze(any) :: {:error, any} | {:ok, <<_::64, _::_*8>>}
  def analyze(language) do
    Logger.info("Github Trending Analysis: {#{language}}")
    uuid = UUID.uuid1()
    check_repo? = check_repo_size?()
    num_of_repos = Application.fetch_env!(:lowendinsight_get, :num_of_repos) || 5

    case fetch_trending_list(language) do
      {:error, reason} ->
        {:error, reason}

      {:ok, list} ->
        urls =
        filter_to_urls(list)
        |> Enum.map(fn url -> get_repo_size(url) end)
        |> Enum.map(fn {repo_size, url} -> filter_out_large_repos({repo_size, url}, check_repo?) end)
        |> Enum.take(num_of_repos)

        Logger.debug("URLS: #{inspect urls}")

        LowendinsightGet.Analysis.process_urls(
          urls,
          uuid,
          DateTime.utc_now()
        )

        # Write the UUID into the gh_trending entry in Redis
        Redix.command(:redix, ["SET", "gh_trending_#{language}_uuid", uuid])
        {:ok, "successfully started analyzing trending repos for job id:#{uuid}"}
    end
  end

  def get_current_gh_trending_report(language) do
    case Redix.command(:redix, ["GET", "gh_trending_#{language}_uuid"]) do
      {:error, reason} ->
        {:error, reason}

      {:ok, uuid} ->
        case uuid do
          nil ->
            %{
              "metadata" => %{"times" => %{}},
              "report" => %{"uuid" => UUID.uuid1(), "repos" => []}
            }
          _ ->
            {:ok, report_json} = Redix.command(:redix, ["GET", uuid])
            Poison.Parser.parse!(report_json, %{})
        end
    end
  end

  defp get_token() do
    if Application.fetch_env(:lowendinsight_get, :gh_token) == :error,
    do: "",
    else: Application.fetch_env!(:lowendinsight_get, :gh_token)
  end

  defp fetch_gh_api_response(token, slug) do
    headers = ["Authorization": "Bearer #{token}", "Accept": "Application/json; Charset=utf-8"]
    HTTPoison.get("https://api.github.com/repos/" <> slug, headers)
  end

  def get_repo_size(url) do
    case Helpers.get_slug(url) do
      {:ok, slug} ->
        {:ok, response} = fetch_gh_api_response(get_token(), slug)
        json = Poison.Parser.parse!(response.body, %{})
        {json["size"], url}
      {:error, msg} -> {:error, msg}
    end
  end

  def filter_out_large_repos({repo_size, url}, check_repo?) when repo_size < 1000000 or not check_repo? do
    url
  end

  def filter_out_large_repos({_repo_size, url}, check_repo?) when check_repo? do
    url <> "-skip_too_big"
  end

  def get_wait_time() do
    if Application.fetch_env(:lowendinsight_get, :wait_time) == :error,
    do: 1800000,
    else: Application.fetch_env!(:lowendinsight_get, :wait_time)
  end

  def check_repo_size?() do
    if Application.fetch_env(:lowendinsight_get, :check_repo_size?) == :error,
      do: false,
      else: Application.fetch_env!(:lowendinsight_get, :check_repo_size?)
  end

  defp filter_to_urls(list) do
    for repo <- list, do: repo["url"]
  end

  defp fetch_trending_list(language) do
    url =
      "https://gh-trending.onrender.com/repositories?since=daily&language=" <> URI.encode_www_form(language)

    Logger.info("fetching trend list for: #{url}")
    case HTTPoison.get(url) |> HTTPoison.Retry.autoretry(max_attempts: 5, wait: 15000, retry_unknown_errors: true) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        {:ok, Poison.Parser.parse!(body, %{})}

      {:ok, %HTTPoison.Response{status_code: 404}} ->
        {:error, "Not found :("}

      {:error, %HTTPoison.Error{reason: reason}} ->
        Logger.error(reason)
        {:error, reason}
    end
  end

end
