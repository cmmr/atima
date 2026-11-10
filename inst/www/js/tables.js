
//___________________________________________________________________
// Used by page_meta and page_taxa to build DataTables
// with dynamic custom headers and server-side paging.
//___________________________________________________________________


//___________________________________________________________________
// Load metadata when the user opens the metadata page
//___________________________________________________________________
$('#page_meta')

  .addClass('reloadable')
  .on('reload shown', function () {
    
    const $page      = $(this);
    const biom_nonce = get_value(['CONF', 'nonce', 'biom']);
    
    if ($page.data('biom_nonce') !== biom_nonce) {

      const $tbl = $('#metadata_table');

      if ($page.is(':visible')) {
      
        ajax_dt($tbl, 'metadata')
          .done(function () {
            $tbl.find('.numcat').on('change', function () {
              api({
                method  : 'metadata_change_class',
                payload : { col_num: $(this).data('colnum') + 1 } });
            });
          });
          
          $page.data('biom_nonce', biom_nonce);

      } else if ($tbl.hasClass('dataTable')) {
        $tbl.DataTable().destroy();
      }

    }

  })

  .addClass('resizable')
  .on('resize', function () {

    const $page        = $(this);
    const resize_nonce = get_value(['CONF', 'nonce', 'resize']);
    
    if ($page.data('resize_nonce') !== resize_nonce) {
      var w = Math.floor($(window).width() - $('#page_meta').offset().left - 20);
      $('#metadata_div').css('max-width', w + 'px');
      $page.data('resize_nonce', resize_nonce);
    }
  });


//___________________________________________________________________
// Upload/download metadata table.
//___________________________________________________________________
$('#metadata_import').on('change', function () {
	upload_component('metadata', this.files[0])
	  .done(() => $('#page_meta').triggerHandler('shown'));
});

$('#metadata_download').on('click', function() {
  download_component('metadata');
});


//___________________________________________________________________
// Load taxonomy when the user opens the taxonomy page.
//___________________________________________________________________
$('#page_taxa')

  .addClass('reloadable')
  .on('reload shown', function () {

    const $page      = $(this);
    const biom_nonce = get_value(['CONF', 'nonce', 'biom']);
    
    if ($page.data('biom_nonce') !== biom_nonce) {

      const $tbl = $('#taxonomy_table');

      if ($page.is(':visible')) {
        ajax_dt($tbl, 'taxonomy');
        $page.data('biom_nonce', biom_nonce);

      } else if ($tbl.hasClass("dataTable")) {
        $tbl.DataTable().destroy();
      }
    }
    //$('#page_taxa').triggerHandler('resize');

  })

  .addClass('resizable')
  .on('resize', function () {

    const $page = $(this);
    const resize_nonce = get_value(['CONF', 'nonce', 'resize']);
    
    if ($page.data('resize_nonce') !== resize_nonce) {
      var w = Math.floor($(window).width() - $('#page_taxa').offset().left - 20);
      $('#taxonomy_div').css('max-width', w + 'px');
      $page.data('resize_nonce',  resize_nonce);
    }
  });


//___________________________________________________________________
// Upload/download taxonomy table.
//___________________________________________________________________
$('#taxonomy_import').on('change', function () {
	upload_component("taxonomy", this.files[0])
	  .done(() => $('#page_taxa').triggerHandler('shown'));
})

$('#taxonomy_download').on('click', function () {
  download_component("taxonomy");
});






function ajax_dt ($tbl, src) {
  
  const id = $tbl.attr('id');
  
  
  // Show a modal while waiting for the datatable to initialize
  const spinner = document.createElement("i");
        spinner.classList.add("fa", "fa-spin", "fa-spinner");
  swal({
    title: "Loading Records", 
    content: spinner, 
    button: false, 
    closeOnClickOutside: false });
  const onFinally = function() { swal.close() };
  
  
  // Destroy existing table
  if ($tbl.hasClass("dataTable")) {
    $tbl.DataTable().destroy();
    $tbl.html('');
  }
  
  // Clear the search
  if ($('#' + src + '_search')) {
    $('#' + src + '_search').val("");
  }
  
  
  // Use the HTML template returned by the server to
  // dynamically define the column names in the table header
  const onSuccess = function (resp) {
    
    $tbl
      .html(resp['html'])
      .DataTable({
        
        serverSide    : true,
        autoWidth     : false,
        dom           : "rtfp",
        processing    : false,
        orderCellsTop : src == "metadata",
        
        ajax          : {
          url         : "/api/" + src + "_dt",
          type        : "POST",
          contentType : "application/json",
          dataType    : "json",
          headers     : get_value(['CONF', 'headers']),
          data        : function (d)     { return JSON.stringify(d); },
          error       : function (jqXHR) { raise_error(src + "_dt", jqXHR.responseText); }
        },
        
        initComplete  : function () {
          
          // Move the components for horizontal scrolling, etc
          var main   = $('<div/>').css({'overflow': "auto"});
          var footer = $('<div/>').css({'margin-top': "10px", 'display': "flex", 'align-items': "center"});
          
          $tbl.parent().append(main, footer);
          main.append($tbl);
          footer.append(
            $('#' + id + '_filter'), 
            $('<div/>').css({'flex-grow': 1}),
            $('#' + id + '_paginate') );
        }
      });
  }
  
  
  return api({
  	'method'    : src + "_thead",
  	'onSuccess' : onSuccess, 
  	'onFinally' : onFinally
  });
  
}
