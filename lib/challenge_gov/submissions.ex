defmodule ChallengeGov.Submissions do
  @moduledoc """
  Context for Submissions
  """

  @behaviour Stein.Filter

  import Ecto.Query

  alias ChallengeGov.Accounts
  alias ChallengeGov.Emails
  alias ChallengeGov.GovDelivery
  alias ChallengeGov.Mailer
  alias ChallengeGov.Repo
  alias ChallengeGov.SecurityLogs
  alias ChallengeGov.SubmissionDocuments
  alias ChallengeGov.Submissions.Submission
  alias ChallengeGov.SubmissionExports
  alias Stein.Filter

  def all(opts \\ []) do
    Submission
    |> base_preload
    |> preload([:phase])
    |> where([s], is_nil(s.deleted_at))
    |> Filter.filter(opts[:filter], __MODULE__)
    |> order_on_attribute(opts[:sort])
    |> Repo.paginate(opts[:page], opts[:per])
  end

  def all_with_manager_id(opts \\ []) do
    Submission
    |> base_preload
    |> where([s], is_nil(s.deleted_at))
    |> where([s], not is_nil(s.manager_id))
    |> preload([:phase, :manager])
    |> Filter.filter(opts[:filter], __MODULE__)
    |> order_on_attribute(opts[:sort])
    |> Repo.paginate(opts[:page], opts[:per])
  end

  def all_by_submitter_id(user_id, opts \\ []) do
    Submission
    |> base_preload
    |> preload([:phase])
    |> where([s], is_nil(s.deleted_at))
    |> where([s], s.submitter_id == ^user_id)
    |> Filter.filter(opts[:filter], __MODULE__)
    |> order_on_attribute(opts[:sort])
    |> Repo.paginate(opts[:page], opts[:per])
  end

  def get(id) do
    Submission
    |> where([s], is_nil(s.deleted_at))
    |> where([s], s.id == ^id)
    |> base_preload
    |> preload([:phase])
    |> preload(challenge: [:phases])
    |> Repo.one()
    |> case do
      nil ->
        {:error, :not_found}

      submission ->
        {:ok, submission}
    end
  end

  def base_preload(submission) do
    preload(submission, [:submitter, :invite, :documents, challenge: [:agency]])
  end

  def new do
    %Submission{}
    |> new_form_preload
    |> Submission.changeset(%{})
  end

  defp new_form_preload(submission) do
    Repo.preload(submission, [:submitter, :documents, challenge: [:agency]])
  end

  def create_draft(params, user, challenge, phase) do
    params = attach_default_multi_params(params)
    changeset = Submission.draft_changeset(%Submission{}, params, user, challenge, phase)

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:submission, changeset)
    |> attach_documents(params)
    |> Repo.transaction()
    |> case do
      {:ok, %{submission: submission}} ->
        GovDelivery.subscribe_user_general(user)
        GovDelivery.subscribe_user_challenge(user, challenge)
        {:ok, submission}

      {:error, _type, changeset, _changes} ->
        changeset = preserve_document_ids_on_error(changeset, params)
        changeset = %Ecto.Changeset{changeset | data: Repo.preload(changeset.data, [:documents])}

        {:error, changeset}
    end
  end

  def create_review(params, user, challenge, phase) do
    params = attach_default_multi_params(params)
    changeset = Submission.review_changeset(%Submission{}, params, user, challenge, phase)

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:submission, changeset)
    |> attach_documents(params)
    |> Repo.transaction()
    |> case do
      {:ok, %{submission: submission}} ->
        submission = new_form_preload(submission)
        if submission.manager_id, do: send_submission_review_email(user, phase, submission)
        {:ok, submission}

      {:error, _type, changeset, _changes} ->
        changeset = preserve_document_ids_on_error(changeset, params)
        changeset = %Ecto.Changeset{changeset | data: Repo.preload(changeset.data, [:documents])}

        {:error, changeset}
    end
  end

  def edit(submission) do
    Submission.changeset(submission, %{})
  end

  def update_draft(submission, params) do
    params = attach_default_multi_params(params)
    changeset = Submission.update_draft_changeset(submission, params)

    Ecto.Multi.new()
    |> Ecto.Multi.update(:submission, changeset)
    |> attach_documents(params)
    |> Repo.transaction()
    |> case do
      {:ok, %{submission: submission}} ->
        {:ok, submission}

      {:error, _type, changeset, _changes} ->
        changeset = preserve_document_ids_on_error(changeset, params)
        {:error, changeset}
    end
  end

  def update_review(submission, params) do
    params = attach_default_multi_params(params)
    changeset = Submission.update_review_changeset(submission, params)

    Ecto.Multi.new()
    |> Ecto.Multi.update(:submission, changeset)
    |> attach_documents(params)
    |> Repo.transaction()
    |> case do
      {:ok, %{submission: submission}} ->
        {:ok, submission}

      {:error, _type, changeset, _changes} ->
        changeset = preserve_document_ids_on_error(changeset, params)
        {:error, changeset}
    end
  end

  defp attach_default_multi_params(params) do
    Map.put_new(params, "documents", [])
  end

  def submit(submission, remote_ip \\ nil) do
    submission
    |> Repo.preload(challenge: [:challenge_owner_users])
    |> Submission.submit_changeset()
    |> Repo.update()
    |> case do
      {:ok, submission} ->
        submission = new_form_preload(submission)
        send_submission_confirmation_email(submission)
        challenge_owner_new_submission_email(submission)
        add_to_security_log(submission.submitter, submission, "submit", remote_ip)
        SubmissionExports.check_for_outdated(submission.phase_id)
        {:ok, submission}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp challenge_owner_new_submission_email(submission) do
    Enum.map(submission.challenge.challenge_owner_users, fn owner ->
      owner
      |> Emails.new_submission_submission(submission)
      |> Mailer.deliver_later()
    end)
  end

  defp send_submission_confirmation_email(submission) do
    submission
    |> Emails.submission_confirmation()
    |> Mailer.deliver_later()
  end

  defp send_submission_review_email(user, phase, submission) do
    user
    |> Emails.submission_review(phase, submission)
    |> Mailer.deliver_later()
  end

  def allowed_to_edit?(user, submission) do
    if submission.submitter_id === user.id or
         (Accounts.has_admin_access?(user) and !is_nil(submission.manager_id)) do
      is_editable?(user, submission)
    else
      {:error, :not_permitted}
    end
  end

  def is_editable?(%{role: "solver"}, submission) do
    if submission.challenge.sub_status === "archived" do
      {:error, :not_permitted}
    else
      submission_phase_is_open?(submission)
    end
  end

  def is_editable?(user, submission) do
    case Accounts.has_admin_access?(user) do
      true ->
        if is_nil(submission.manager_id) or
             !!submission.review_verified or
             submission.challenge.sub_status === "archived" do
          {:error, :not_permitted}
        else
          {:ok, submission}
        end

      false ->
        {:error, :not_permitted}
    end
  end

  def submission_phase_is_open?(submission) do
    phase_close = submission.phase.end_date
    now = Timex.now()

    case Timex.compare(phase_close, now) do
      1 ->
        {:ok, submission}

      tc when tc == -1 or tc == 0 ->
        {:error, :not_permitted}
    end
  end

  def allowed_to_delete?(user, submission) do
    if submission.submitter_id === user.id or
         (Accounts.has_admin_access?(user) and !is_nil(submission.manager_id)) do
      {:ok, submission}
    else
      {:error, :not_permitted}
    end
  end

  def delete(submission) do
    soft_delete(submission)
  end

  defp soft_delete(submission) do
    submission
    |> Submission.delete_changeset()
    |> Repo.update()
    |> case do
      {:ok, submission} ->
        {:ok, submission}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # Attach supporting document functions
  defp attach_documents(multi, %{document_ids: ids}) do
    attach_documents(multi, %{"document_ids" => ids})
  end

  defp attach_documents(multi, %{"document_ids" => ids}) do
    Enum.reduce(ids, multi, fn document_id, multi ->
      Ecto.Multi.run(multi, {:document, document_id}, fn _repo, changes ->
        document_id
        |> SubmissionDocuments.get()
        |> attach_document(changes.submission)
      end)
    end)
  end

  defp attach_documents(multi, _params), do: multi

  defp attach_document({:ok, document}, submission) do
    SubmissionDocuments.attach_to_submission(document, submission)
  end

  defp attach_document(result, _challenge), do: result

  defp preserve_document_ids_on_error(changeset, %{"document_ids" => ids}) do
    {document_ids, documents} =
      Enum.reduce(ids, {[], []}, fn document_id, {document_ids, documents} ->
        case SubmissionDocuments.get(document_id) do
          {:ok, document} ->
            {[document_id | document_ids], [document | documents]}

          _ ->
            {document_ids, documents}
        end
      end)

    changeset
    |> Ecto.Changeset.put_change(:document_ids, document_ids)
    |> Ecto.Changeset.put_change(:document_objects, documents)
  end

  defp preserve_document_ids_on_error(changeset, _params), do: changeset

  def update_judging_status(submission, judging_status) do
    submission
    |> Submission.judging_status_changeset(judging_status)
    |> Repo.update()
    |> case do
      {:ok, submission} ->
        SubmissionExports.check_for_outdated(submission.phase_id)
        {:ok, submission}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc false
  def statuses(), do: Submission.statuses()

  @doc false
  def status_label(status) do
    status_data = Enum.find(statuses(), fn s -> s.id == status end)

    if status_data do
      status_data.label
    else
      status
    end
  end

  defp add_to_security_log(user, submission, type, remote_ip, details \\ nil) do
    SecurityLogs.track(%{
      originator_id: user.id,
      originator_role: user.role,
      originator_identifier: user.email,
      originator_remote_ip: remote_ip,
      target_id: submission.id,
      target_type: "submission",
      target_identifier: submission.title,
      action: type,
      details: details
    })
  end

  def get_all_with_user_id_and_manager(user) do
    from(s in Submission,
      where: s.submitter_id == ^user.id,
      where: not is_nil(s.manager_id),
      where: s.status == "draft",
      select: s
    )
    |> Repo.all()
  end

  # BOOKMARK: Filter functions
  @impl Stein.Filter
  def filter_on_attribute({"search", value}, query) do
    value = "%" <> value <> "%"

    where(
      query,
      [s],
      ilike(s.title, ^value) or ilike(s.brief_description, ^value) or ilike(s.description, ^value) or
        ilike(s.external_url, ^value) or ilike(s.status, ^value)
    )
  end

  def filter_on_attribute({"submitter_id", value}, query) do
    where(query, [c], c.submitter_id == ^value)
  end

  def filter_on_attribute({"challenge_id", value}, query) do
    where(query, [c], c.challenge_id == ^value)
  end

  def filter_on_attribute({"phase_id", value}, query) do
    where(query, [c], c.phase_id == ^value)
  end

  def filter_on_attribute({"phase_ids", value}, query) do
    where(query, [s], s.phase_id in ^value)
  end

  def filter_on_attribute({"title", value}, query) do
    value = "%" <> value <> "%"
    where(query, [s], ilike(s.title, ^value))
  end

  def filter_on_attribute({"brief_description", value}, query) do
    value = "%" <> value <> "%"
    where(query, [s], ilike(s.brief_description, ^value))
  end

  def filter_on_attribute({"description", value}, query) do
    value = "%" <> value <> "%"
    where(query, [s], ilike(s.description, ^value))
  end

  def filter_on_attribute({"external_url", value}, query) do
    value = "%" <> value <> "%"
    where(query, [s], ilike(s.external_url, ^value))
  end

  def filter_on_attribute({"status", value}, query) do
    value = "%" <> value <> "%"
    where(query, [s], ilike(s.status, ^value))
  end

  def filter_on_attribute({"judging_status", "all"}, query), do: query

  def filter_on_attribute({"judging_status", "selected"}, query) do
    where(query, [s], s.judging_status == "selected" or s.judging_status == "winner")
  end

  def filter_on_attribute({"judging_status", value}, query) do
    where(query, [s], s.judging_status == ^value)
  end

  def filter_on_attribute({"manager_id", value}, query) do
    where(query, [s], s.manager_id == ^value)
  end

  def filter_on_attribute({"managed_accepted", "true"}, query) do
    where(
      query,
      [s],
      (s.review_verified == true and s.terms_accepted == true) or is_nil(s.manager_id)
    )
  end

  def filter_on_attribute({"managed_accepted", _value}, query), do: query

  def order_on_attribute(query, %{"challenge" => direction}) do
    query = join(query, :left, [s], c in assoc(s, :challenge), as: :challenge)

    case direction do
      "asc" ->
        order_by(query, [s, challenge: c], asc_nulls_last: c.title)

      "desc" ->
        order_by(query, [s, challenge: c], desc_nulls_last: c.title)

      _ ->
        query
    end
  end

  def order_on_attribute(query, %{"phase" => direction}) do
    query = join(query, :left, [s], p in assoc(s, :phase), as: :phase)

    case direction do
      "asc" ->
        order_by(query, [s, phase: p], asc_nulls_last: p.title)

      "desc" ->
        order_by(query, [s, phase: p], desc_nulls_last: p.title)

      _ ->
        query
    end
  end

  def order_on_attribute(query, %{"manager_last_name" => direction}) do
    query = join(query, :left, [s], m in assoc(s, :manager), as: :manager)

    case direction do
      "asc" ->
        order_by(query, [s, manager: m], asc_nulls_last: m.last_name)

      "desc" ->
        order_by(query, [s, manager: m], desc_nulls_last: m.last_name)

      _ ->
        query
    end
  end

  def order_on_attribute(query, sort_columns)
      when is_map(sort_columns) and map_size(sort_columns) > 0 do
    columns_to_sort =
      Enum.reduce(sort_columns, [], fn {column, direction}, acc ->
        column = String.to_atom(column)

        case direction do
          "asc" ->
            acc ++ [asc_nulls_last: column]

          "desc" ->
            acc ++ [desc_nulls_last: column]

          _ ->
            []
        end
      end)

    order_by(query, [c], ^columns_to_sort)
  end

  def order_on_attribute(query, _), do: order_by(query, [c], desc_nulls_last: :id)
end