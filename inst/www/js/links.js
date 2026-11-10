

//___________________________________________________________________
// Handle updating project title and UAC controls.
//___________________________________________________________________
$('body>header').on('reload', function () {

  const $header  = $(this);
  const is_guest = get_value(['CONF', 'is_guest'], true);
  
  $header.children('a').addClass('d-none');

  if (is_guest) {
    $header.children(':contains("Sign In")').removeClass('d-none');
    $header.children(':contains("New Account")').removeClass('d-none');

  } else {
    $header.children(':contains("My Account")').removeClass('d-none');
    $header.children(':contains("Log Out")').removeClass('d-none');
    $('#private_tab').triggerHandler('click');
    migrate_projects();
  }
  
});

$('body>header>a').on($.modal.AJAX_COMPLETE, function () {

  const $modal = $.modal.getCurrent().$elm;

  $modal.find('.serialize-submit').on('click', function (e) {
  
    const $button = $(this);
    const $form   = $button.parent();
    
    $button.prop('disabled', true);
    
    api({
      method    : $button.data('api'),
      payload   : $form.serializeObject(),
      onSuccess : function (resp) {
        // Keep modal open if a non-success swal is returned.
        if (!resp['swal'] || resp['swal']['icon'] != 'success')
          $.modal.close();
      },
      onFinally : function () { $button.prop('disabled', false); }
    });
    
  });
});


//___________________________________________________________________
// Left menu - show/collapse dropdowns, add/remove active class
//___________________________________________________________________
$('body>nav').on('click', 'h1,li', async function (e) {

  const $nav    = $(this);
  const $hgroup = $nav.closest('hgroup');

  if ($hgroup.is(':not(:active)')) {
    $('body>nav hgroup').removeClass('active');
    $hgroup.addClass('active');
  }

  $('body>nav li.active').removeClass('active');
  if ($nav.is('li')) $nav.addClass('active');
  
  
  //---------------------------------------------
  // Switch to the selected page
  //---------------------------------------------
  const nav_page = $nav.data('page');

  set_value(['CONF', 'control_set_id'], $nav.data('controls'));
  set_value(['CONF', 'plot_fn'],        $nav.data('fn'));

  if (nav_page) {

    set_value(['CONF', 'nav_page'], nav_page);

    const $page = $('#page_' + nav_page);
    $page.addClass('active').shown();
    $page.siblings().removeClass('active');

    $('body>menu>*:not(.save)').removeClass('active');
    $('body>menu>.' + nav_page).addClass('active');
  }
  
});


//___________________________________________________________________
// Top menu - open modals on click
//___________________________________________________________________
// $('body>header>a').on('click', function (e) {
//   const x = $(this).text().toLowerCase().replace(' ', '_');
//   $('#' + x + '_modal').modal({ fadeDuration: 100 });
// });


//___________________________________________________________________
// 'Log Out' modal only launches when data isn't saved.
//___________________________________________________________________
$('#uac_log_out').off('click').on('click', function () {
  if (is_saved()) {
    $('#log_out_modal').find('button').triggerHandler('click');
  } else {
    $('#log_out_modal').modal({ fadeDuration: 100 });
  }
});




//___________________________________________________________________
// Tabbed menu - show content on click
//___________________________________________________________________
$('.tabs').on('click', '.tab', function (e) {
  
  $(this).siblings().removeClass('active');
  $(this).addClass('active');
  
  const $target = $('#' + $(this).data('target'));
  
  $target.siblings().hide();
  $target.show().triggerHandler('shown');
});




//___________________________________________________________________
// Create links for all available metrics.
//___________________________________________________________________
$('#page_expt')

  .addClass('reloadable')
  .on('reload shown', function () {

    const $page      = $(this);
    const biom_nonce = get_value(['CONF', 'nonce', 'biom']);

    if ($page.data('biom_nonce') !== biom_nonce) {

      if ($page.is(':visible')) {

        $page.data('biom_nonce', biom_nonce);
        
        $('#expt_bdiv_matrices')
          .html(get_value(['BIOM', 'bdiv_options']).map((x) => '' + 
            '<tr>' +
              '<td>' + x + ':</td>' + 
              '<td><a data-export="beta/' + x.toLowerCase() + '/w" href="#">Weighted</a></td>' +
              '<td><a data-export="beta/' + x.toLowerCase() + '/u" href="#">Unweighted</a></td>' +
            '</tr>').join(''));
        
        $('#expt_taxa_matrices')
          .html(get_value(['BIOM', 'rank_options']).map((x) => '' + 
            '<tr>' +
              '<td>' + x + ':</td>' +
              '<td><a data-export="taxa/' + x.toLowerCase() + '/rare" href="#">Rarefied</a></td>' +
              '<td><a data-export="taxa/' + x.toLowerCase() + '/full" href="#">Unrarefied</a></td>' +
            '</tr>').join(''));
            
      } else {
        $('#expt_bdiv_matrices').html('');
        $('#expt_taxa_matrices').html('');
      }
          
    }
    
  });




//___________________________________________________________________
// Download the requested data to the user's computer.
//___________________________________________________________________
$('#page_expt').on('click', 'a', function() {
  
  api({
  	'method'      : "export/" + $(this).data('export'),
	  'spinner_msg' : "Exporting file...",
	  'onSuccess'   : function (resp) {
	    trigger_download(resp['download_url']); } });
});

