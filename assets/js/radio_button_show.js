$(document).ready(function(){
  if ($(".upload-logo input[type=radio][value=true]:checked").length > 0) {
    $(".logo-file-field").collapse("show")
  }

  $(".upload-logo input[type=radio]").on("click", function() {
    if ($(this).val() == "true") {
      $(".logo-file-field").collapse("show")
    } else {
      $(".logo-file-field").collapse("hide")
      $(".logo-file-field input").val("")
    }
  })
  
  // Adding phases show/hide section
  if ($(".multi-phase-toggle input[type=radio][value=true]:checked").length > 0) {
    $(".phase-fields .nested-items").find("input").prop("disabled", false)
    $(".phase-fields").collapse("show")
    $(".single-phase-section").collapse("hide")
  }

  if ($(".multi-phase-toggle input[type=radio][value=false]:checked").length > 0) {
    $(".phase-fields .nested-items").find("input").prop("disabled", true)
    $(".phase-fields").collapse("hide")
    $(".single-phase-section").collapse("show")
  }

  $(".multi-phase-toggle input[type=radio]").on("click", function() {
    if ($(this).val() == "true") {
      $(".phase-fields").collapse("show")
      $(".single-phase-section").collapse("hide")
      $(".phase-fields .nested-items").find("input").prop("disabled", false)
    } else {
      if (window.confirm("This will remove all information from any phases you may have created. Are you sure?")) {
        $(".phase-fields").collapse("hide")
        $(".single-phase-section").collapse("show")
        $(".phase-fields .nested-items").find("input").prop("disabled", true)
        return true
      } else {
        return false
      }
    }
  })

  // Prize details show/hide input  
  const prizeTotalSection = $(".js-prize-total.collapse")
  const nonMonetaryPrizeSection = $(".js-non-monetary-prize.collapse")

  if ($(".js-prize-detail-toggle input[type=radio][value='monetary']:checked").length > 0) {
    showMonetaryPrize()
  }

  if ($(".js-prize-detail-toggle input[type=radio][value='non_monetary']:checked").length > 0) {
    showNonMonetaryPrize()
  }

  if ($(".js-prize-detail-toggle input[type=radio][value='both']:checked").length > 0) {
    showBothPrizes()
  }

  $(".js-prize-detail-toggle input[type=radio]").on("click", function() {
    switch ($(this).val()) {
      case "monetary":
        return showMonetaryPrize()
      case "non_monetary":
        return showNonMonetaryPrize()
      case "both":
        return showBothPrizes()
      default:
        console.log("Could not show prize inputs")
        break;
    }
  })

  function showMonetaryPrize() {
    prizeTotalSection.collapse("show")
    prizeTotalSection.find("input").prop("disabled", false)
    nonMonetaryPrizeSection.collapse("hide")
    nonMonetaryPrizeSection.find("input").prop("disabled", true)
  }

  function showNonMonetaryPrize() {
    nonMonetaryPrizeSection.collapse("show")
    nonMonetaryPrizeSection.find("input").prop("disabled", false)
    prizeTotalSection.collapse("hide")
    prizeTotalSection.find("input").prop("disabled", true)
  }

  function showBothPrizes() {
    prizeTotalSection.collapse("show")
    prizeTotalSection.find("input").prop("disabled", false)
    nonMonetaryPrizeSection.collapse("show")
    nonMonetaryPrizeSection.find("input").prop("disabled", false)
  }
})