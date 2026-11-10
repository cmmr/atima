



//___________________________________________________________________
// Make sure the jsTree can fill 100% of the height.
//___________________________________________________________________
// $('#page_home').on('shown', function() {
//   $('#page_home').triggerHandler('resize');
//   $('#intro_preview').append($('#preview'));
// });


//___________________________________________________________________
// BIOM file uploads
//___________________________________________________________________
$('#biom_import').on('change', function () {
  
  // Uploading files requires a more complex object.
  const payload = new FormData();  
        payload.append("biom_file", this.files[0]);
  
      
  // resp['BIOM', 'jstree_node'] handled by api()
  api({
  	'method'      : "upload_biom",
	  'payload'     : payload,
	  'spinner_msg' : "Loading BIOM file." });
  
});




//___________________________________________________________________
// Handle updating project title and UAC controls.
//___________________________________________________________________
$('body>header')

  .addClass('reloadable')
  .on('reload', function () {

    const $header     = $(this);
    const title       = get_value(['BIOM', 'title']);
    const project_key = get_value(['BIOM', 'project_key']);
    const project_url = build_url(project_key);
    
    $header.children('h1').text(title);
    document.title = title + ' | atima';
    
    // Update the URL so this project is bookmark-able
    if (window.location.href !== project_url) {
      window.history.pushState({}, document.title, project_url);
    }
    
  });



//___________________________________________________________________
// Save buttons - respond to writable/unsaved variables.
//___________________________________________________________________
$('#save_btn')

  .addClass('reloadable')
  .on('reload', function () {
    $(this)
      .toggleClass('unsaved',  !is_saved())
      .toggleClass('readonly', !get_value(['BIOM', 'is_editor']));
  })
  
  .on('click', function () {
    api({
      'spinner_msg' : 'Saving...',
    	'method'      : 'save',
      'payload'     : {
        title       : get_value(['BIOM', 'unsaved_title'])       || get_value(['BIOM', 'title']),
        access_key  : get_value(['BIOM', 'unsaved_access_key'])  || get_value(['BIOM', 'access_key']),
        description : get_value(['BIOM', 'unsaved_description']) || get_value(['BIOM', 'description']) },
    });
  });


$('#save_as_btn')

  .addClass('reloadable')
  .on('reload', function () {
    $(this).toggleClass('unsaved', !(is_saved() || get_value(['BIOM', 'is_editor'])));
  })

  .on('click', function () {

    if (get_value(['CONF', 'is_guest'])) {
      
      swal({
        title: "Not Logged In",
        text: "Please log in to your account before saving." });

    } else {
    
      swal({
        title: 'New Title',
        text: 'A copy of this project will be saved to your private datasets collection.',
        content: {
          element: 'input',
          attributes: { value: get_value(['BIOM', 'unsaved_title']) || get_value(['BIOM', 'title']) } },
        buttons: { cancel: true, confirm: true }
      })
      .then((new_title) => {
        if (new_title) {
          api({
            'spinner_msg' : 'Saving...',
            'method'      : 'save_as',
            'payload'     : {
              title       : new_title,
              access_key  : get_value(['BIOM', 'unsaved_access_key'])  || get_value(['BIOM', 'access_key']),
              description : get_value(['BIOM', 'unsaved_description']) || get_value(['BIOM', 'description']) }
          });
        }
      });

    }
    
  });


//___________________________________________________________________
// Import updated project details
//___________________________________________________________________
function load_biom (new_biom) {
  
  console.log('load_biom:');
  console.log(new_biom);
  console.log('');
  
  // Cancel any pending timeout to avoid mixing old and new datasets.
  clearTimeout($('#plot_results').data('timeout'));

  window.BIOM = new_biom;
  window.SYNC = {};
  
  jsTree_highlight_node();
  
  increment_value(['CONF', 'nonce', 'biom']);
  increment_value(['CONF', 'nonce', 'combo']);

  default_value(['SYNC', 'colors_bool'], true);
  
  $('#controls,.reloadable').reload().configure().sync();

  if ($('#page_plot').length > 0) plot_rebuild();
};



//___________________________________________________________________
// See if logging out would cause any data loss.
//___________________________________________________________________
function is_saved () {

  let saved = get_value(['BIOM', 'is_saved']);
      saved = saved && !get_value(['BIOM', 'unsaved_title'],       false);
      saved = saved && !get_value(['BIOM', 'unsaved_access_key'],  false);
      saved = saved && !get_value(['BIOM', 'unsaved_description'], false);
  
  return saved;
}





// direction can be 'prev' or 'next'.
function gallery_cycle (direction = 'next', fade = true, force = false) {

  // Skip when the gallery isn't visible.
  if (force === false) {
    if ($('#gallery').is(':hidden'))           { return null; }
    if (document.visibilityState === 'hidden') { return null; }
    if (document.hidden)                       { return null; }
    if (!document.hasFocus())                  { return null; }
  }
  
  let   interval = get_value(['CONF', 'gallery', 'interval'], null);
  let   i        = get_value(['CONF', 'gallery', 'i'],        1);
  const images   = get_value(['CONF', 'gallery', 'images'],   []);
  const n        = images.length;
  if (n < 2) { return null; }


  if (direction === 'prev') { // pause automatic cycling.
    i = i - 1;
    if (interval !== null) {
      clearInterval(interval);
      interval = null;
    }

  } else if (direction === 'next') { // resume automatic cycling.
    i = i + 1;
    if (interval === null) {
      interval = setInterval(_.debounce(gallery_cycle, 1000), 15000);
    }
  }

  if (i <= 1) i = n + 1;
  const curr_image = 'url(/www/img/gallery/' + images[i % n]       + ')';
  const prev_image = 'url(/www/img/gallery/' + images[(i - 1) % n] + ')';
  const next_image = 'url(/www/img/gallery/' + images[(i + 1) % n] + ')';
  
  set_value(['CONF', 'gallery', 'i'],        i);
  set_value(['CONF', 'gallery', 'interval'], interval);
  
  
  if (fade) {
    
    // Fade out, change the content, then fade in again.
    $("#gallery_curr_image")
      .fadeTo(1000, 0.10, function () {
        $('#gallery_curr_image').css("background-image", curr_image);
        $('#gallery_prev_image').css("background-image", prev_image);
        $('#gallery_next_image').css("background-image", next_image);
      })
      .fadeTo(500,1);
      
  } else {
    $('#gallery_curr_image').css("background-image", curr_image);
    $('#gallery_prev_image').css("background-image", prev_image);
    $('#gallery_next_image').css("background-image", next_image);
  }
};


$('#gallery_next, #gallery_next_image').on('click', function () { gallery_cycle('next', false, true); });
$('#gallery_prev, #gallery_prev_image').on('click', function () { gallery_cycle('prev', false, true); });
