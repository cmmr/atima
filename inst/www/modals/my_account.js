//___________________________________________________________________
// Load values into 'My Account' modal.
//___________________________________________________________________
api({
  method    : 'account_details',
  onSuccess : function (resp) {
    const $modal = $('.modal>form');
    $modal.find('input[name="full_name"]').val(resp['full_name']);
    $modal.find('input[name="affiliation"]').val(resp['affiliation']);
    $modal.find('input[name="email"]').val(resp['email']);
  }
});
