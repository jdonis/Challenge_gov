csrf_token = $("input[name='_csrf_token']").val()

$.ajaxPrefilter(function (options, originalOptions, jqXHR) {
  jqXHR.setRequestHeader('X-CSRF-Token', csrf_token);
});

$("#solution_document_upload").on("click", function(e) {
  name_input = $("#solution_document_name")
  name = name_input.val()
  solver_email_input = $("#solution_solver_addr")
  solver_email = solver_email_input.val()
  file_input = $("#solution_document")
  file = file_input.prop("files")[0]

  fd = new FormData()
  fd.append("document[file]", file)
  fd.append("document[name]", name)
  fd.set("solver_email", solver_email)

  if (file) {
    $.ajax({
        url: "/api/submission_documents",
      type: "post",
      processData: false,
      contentType: false,
      data: fd,
      success: function(document) {
        $("#solution_document_upload_error").text("")
        $(name_input).val("")
        $(file_input).val("")

        $(".solution-documents-list").append(`
          <div>
            <i class="fa fa-paperclip mr-1"></i>
            <a href=${document.url} target="_blank">${document.display_name}</a>
            <a href="" data-document-id=${document.id} class="challenge_uploaded_document_delete">
              <i class="fa fa-trash"></i>
            </a>
          </div>
        `)

        $(".solution-document-ids").append(`
          <input type="hidden" name="solution[document_ids][]" value="${document.id}">
        `)
      },
      error: function(err) {
        console.log("Something went wrong")
        handleFileUploadError(err.responseJSON.errors)
      }
    })
  }
})

const handleFileUploadError = (errors) => {
  if (errors["solver_addr"]) {
    $("#solution_document_upload_error").text(`${errors["solver_addr"]}`)
  }
}

$(".solution-documents-list").on("click", ".solution_uploaded_document_delete", function(e) {
  e.preventDefault()

  document_id = $(this).data("document-id")
  parent_element = $(this).parents(".solution-document-row")

  $.ajax({
    url: `/api/submission_documents/${document_id}`, 
    type: "delete",
    processData: false,
    contentType: false,
    success: function(res) {
      parent_element.remove()
    },
    error: function(err) {
      console.log("Something went wrong")
    }
  })
})
