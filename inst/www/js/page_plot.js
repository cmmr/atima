
//___________________________________________________________________
// First time page is shown() initialize controls, etc.
//___________________________________________________________________
$('#page_plot').on('shown', async function () {

  $('#page_plot').off('shown');
  

  //___________________________________________________________________
  // Initialize the controls.
  //___________________________________________________________________
  const { controls_init } = await import('/www/modules/controls.js');
  await controls_init();



  //___________________________________________________________________
  // Check if the plot needs to be rebuilt.
  //___________________________________________________________________
  $('#page_plot')

    .addClass('reloadable')
    .on('reload', function () {  // Clear the plot panels.
      $('#figure_panel').html('');
      $('#code_panel>pre>code').html('');
      $('#stats_table').find('.dataTable').each(function() { $(this).DataTable().destroy(); });
      $('#stats_table').empty().html('');
      $(this).children().reload();
    })
  
    .addClass('resizable')
    .on('resize', function () {  // Sync plot size to window size.
        $('#plot_width').val(Math.floor($('#plot_results').width()));
        $('#plot_height').val(Math.floor($('#plot_results').height() - 10));
        if ($('#figure_panel').is(':visible')) plot_rebuild();
    })

    .on('shown', function () {  // Switch to the 'Figure' tab
      if (!$('#figure_tab').hasClass('active')) {
        $('#figure_tab').triggerHandler('click');
      }
      $('#controls').triggerHandler('configure');
      $('#figure_panel').triggerHandler('shown');
      plot_rebuild();
    })

    .reload().resize().shown();



  //___________________________________________________________________
  // Only transfer stats/code when needed.
  //___________________________________________________________________
  $('#stats_panel,#code_panel').on('shown', function() {
    if (!$('#plot_results').data('attrs')) {
      plot_rebuild();
    }
  });


  //___________________________________________________________________
  // Download a file in the given format
  //___________________________________________________________________
  $('#figure_download').on('click', function() {
    
    const payload      = get_inputs();
    payload['depth']   = get_value(['BIOM', 'depth']);
    payload['plot_fn'] = get_value(['CONF', 'plot_fn']);
    payload['save_args']['device'] = $('#figure_format').val();
    
    api({
      'method'    : 'plot', 
      'payload'   : payload,
      'onSuccess' : function (resp) {
        trigger_download(resp['image_url']); }
    });
    
  });


});




function controls_sync () {
  $('#controls').children(':visible').sync();
}



//___________________________________________________________________
// For the onClick event of show/hide code buttons.
//___________________________________________________________________
function toggle_code_block () {
  const $this  = $(this);
  const target = $this.parent().children('pre').toggle();
  if (target.is(':visible')) { $this.text('hide code');
  } else                     { $this.text('show code'); }
}



//___________________________________________________________________
// Collect the values from currently shown controls.
//___________________________________________________________________
function get_inputs (result = {}) {
  
  result['subset_args'] ||= {};
  result['plot_args']   ||= {};
  result['save_args']   ||= {};
  
  $('#controls').children(':visible').collect(result);
  
  return result;
}


//___________________________________________________________________
// For instance 'bp_pt_size' => 'pt.size'
//___________________________________________________________________
function guess_param (p) {

  if (p['param'] !== undefined) return p['param'];

  // Need to phase out this function.
  debugger;
  
  return (p['sync_id'] || p['id'])
    .replace(/^(bp|rc|hm|sb|adiv|bdiv|bdor|dist|rare)_/, '')
    .replace(/_(cat|num|bool)$/, '')
    .replace('_', '.');
};


//___________________________________________________________________
// Limit the number of times plot_api_request() is called.
//___________________________________________________________________
function plot_rebuild () {
  clearTimeout($('#plot_results').data('timeout'));
  const timeout = setTimeout(plot_api_request, 500);
  $('#plot_results').data('timeout', timeout);
}


//___________________________________________________________________
// Create the requested plot.
//___________________________________________________________________
function plot_api_request () {
  
  // Don't try to generate a plot for non-plot webpages
  const plot_fn = get_value(['CONF', 'plot_fn']);
  if (!plot_fn) { return null; }
  
  
  // Everything to hand to the R backend
  const payload      = get_inputs();
  payload['depth']   = get_value(['BIOM', 'depth']);
  payload['plot_fn'] = plot_fn;
  payload['attrs']   = $('#figure_panel').is(':hidden');
  
  console.log(payload);
  
  
  // How to update the front end.
  const onSuccess = function (resp) {
    
    // Note if stats/code is present
    $('#plot_results').data('attrs', resp['attrs']);
    
    
    // Figure Tab
    $('#figure_panel').html(
      '<img src="' + resp['image_url'] + '"' +
      ' width='    + resp['width'] + 
      ' height='   + resp['height'] + 
      '>' );
    
    
    // Code Tab
    $('#code_panel>pre>code').html('');
    if (resp['attrs']) {
      
      let figure_code = [
        '# Generate this plot using rbiom.',
        '#======================================================',
        'library(rbiom)', 
        'biom <- as_rbiom("' + build_url(resp['code']['file']) + '")',
        resp['code']['rbiom'],
        '\n',
        '# To further customize the plot, modify the code below.',
        '#======================================================',
        'library(ggplot2)',
        'biom <- as_rbiom("' + build_url(resp['code']['file']) + '")',
        resp['code']['ggplot2'],
      ].join('\n');
      
      figure_code = hljs.highlight(figure_code, {language: 'r'}).value;
      $('#code_panel>pre>code').html(figure_code);
    }
    
    
    // Stats Tab
    $('#stats_table').find('.dataTable').each(function() { $(this).DataTable().destroy(); });
    $('#stats_table').empty().html('');
    
    if (resp['stats_table']) {
      
      const tbl_name = '';
      
      const tbl = $('<table/>')
        .attr('id', 'stats_dt')
        .addClass('compact stripe')
        .appendTo($('#stats_table'));
        
      tbl.DataTable({
        
        data          : resp['stats_table'],
        columns       : Object.keys(resp['stats_table'][0]).map(function (val) { return { data: val, title: val } }),
      
        serverSide    : false,
        autoWidth     : false,
        stateSave     : true,
        processing    : false,
        dom           : 'Brtfp',
        language      : {
          search: '_INPUT_',
          searchPlaceholder: 'search'
        },
        
        buttons       : [{
          extend: 'collection',
          text:   '<i class="fa fa-gear fa-lg" style="color:gray"></i>',
          dropup: true,
          buttons: [{
              extend: 'csv',
              text: 'Download as CSV',
              autoClose: true
            },{
              extend: 'colvis',
              dropup: true,
              collectionLayout: 'two-column'
            },{
              extend: 'pageLength',
              dropup: true,
              autoClose: true
            }]
        }],
        lengthMenu: [
            [ 10, 25, 50, -1 ],
            [ '10 rows', '25 rows', '50 rows', 'Show all' ]
        ],
        
        initComplete  : function () {
          
          // Add mouseover alt text to table column names.
          tbl.children('thead').children('tr').children('th').each(function () {
            const colname = $(this).text();
            const tooltip = TOOLTIPS[colname];
            if (tooltip) {
              const $el = $('<span class="tooltip"/>').attr('title', tooltip).text(colname);
              if (colname === 'r_sqr') $el.html('<i>R</i><sup>2</sup>');
              if (colname === 'adj_r') $el.html('adj_<i>R</i><sup>2</sup>');
              $(this).empty().append($el);
            }
          });
          
          
          // Move the components for horizontal scrolling, etc.
          let wrapper = $('#stats_dt_wrapper');
          let main    = $('<div/>').css({'overflow': 'auto'});
          
          tbl.parent().append(main);
          $('<div class="dt-footer"/>')
            .append(
              wrapper.children('.dt-buttons'), 
              $('#stats_dt_filter'), 
              $('<div/>').css({'flex-grow': 1}),
              $('#stats_dt_paginate') )
            .appendTo(tbl.parent());
          main.append(tbl);
          
          
          let description = $('<div/>');
          
          // Add title, methodology, and code.
          $.each(resp['stats_title'], function (key, val) {
            let el = $('<h3/>').text(val).appendTo(description);
            if (val.indexOf(' ~ ') >= 0) el.css({'font-style': 'italic', 'font-family': 'monospace'});
          });
          
          
          if (resp['code']['stats']) {
            
            // code block
            $('<pre style="border:1px solid lightblue; margin:10px; padding:10px; border-radius:5px; overflow-x:auto">' +
                '<code style="white-space:pre; font-family:monospace">' + 
                  hljs.highlight(
                      'library(rbiom)\n' + 
                      'biom <- as_rbiom("' + build_url(resp['code']['file']) + '")\n' + 
                      resp['code']['stats'], 
                    {language: 'r'} ).value + 
                '</code>' + 
              '</pre>')
              .hide()
              .appendTo(description);
            
            // show/hide button
            $('<button style="float:right; font-size:10px">show code</button>')
              .prependTo(description)
              .on('click', toggle_code_block);
          }
          
          wrapper.prepend(description);
        }
      });
        
    }
  }
  
  
  const xhr = api({
  	'method'      : 'plot', 
  	'payload'     : payload, 
  	'onSuccess'   : onSuccess, 
    'spinner_msg' : 'Calculating ' + $('body>nav li.active').text()
  })

  return xhr;
  
};



