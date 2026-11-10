


//___________________________________________________________________
// Abort user's server-side jobs when the page is closed.
//___________________________________________________________________
$( window ).on('beforeunload', function() {
  api({ method: "abort" });
});


//___________________________________________________________________
// Show a spinner while AJAX request is pending.
//___________________________________________________________________
$( document ).ajaxStart(function() {
  const $spinner = $('#spinner');
  const page_id  = $('main>article.active').attr('id');
  if (page_id == 'page_plot') { $spinner.css('right', '230px'); }
  else                        { $spinner.css('right', '0');     }
  $spinner.show();
});

$( document ).ajaxStop(function() {
  $('#spinner').hide();
});



//___________________________________________________________________
// Automatically handle common responses.
//___________________________________________________________________
$( document ).ajaxSuccess(function(event, jqXHR, params, resp) {
  const new_session_key = jqXHR.getResponseHeader('x-session-key');
  if (new_session_key)     set_value(['CONF', 'headers', 'x-session-key'], new_session_key);
  if (resp['swal'])        swal(resp['swal']);
  if (resp['jstree_node']) jsTree_insert(resp['jstree_node']);
  if (resp['jstree_data']) jsTree_rebuild(resp['jstree_data']);
  if (resp['CONF'])        _.merge(get_value(['CONF']), resp['CONF']);
  if (resp['BIOM'])        load_biom(resp['BIOM']);
});

$( document ).ajaxError(function(event, jqXHR, params, thrownError) {
  if (params.url != '/api/heartbeat') // Ignore unsuccessful heartbeat pings
    if (jqXHR.status != 409 && jqXHR.status != 499) // Ignore non-timeout interrupts
      raise_error(params.url, jqXHR.responseText);
});




//___________________________________________________________________
// AJAX wrapper for communicating with backend
//___________________________________________________________________
function api (args) {
  
  //-------------------------------------------------------
  // Present a confirmation message before proceeding.
  //-------------------------------------------------------
  if (args['confirm'] && args['confirmed'] !== true) {

    $('.swal-overlay').data('api_nonce', 0);
    
    swal({
      title      : "Are you sure?",
      text       : args['confirm'],
      icon       : "warning",
      buttons    : true,
      dangerMode : true,
    })
    .then((confirmed) => {
      if (confirmed) {
        args['confirmed'] = true;
        xhr = api(args);
      } else {
        xhr = undefined;
      }
    });

    return xhr;
  }
  

  //-------------------------------------------------------
  // A message to display beneath the loading spinner.
  //-------------------------------------------------------
  $('#spinner_msg').text(args['spinner_msg'] || 'Calculating...');
  
  
  //-------------------------------------------------------
  // General/default xhr request parameters.
  //-------------------------------------------------------
  const params = {
    url     : "/api/" + args['method'],
    type    : "POST",
    headers : get_value(['CONF', 'headers'])
  };
  
  
  //-------------------------------------------------------
  // Configure the payload.
  // When uploading a file, use multipart/form-data.
  //-------------------------------------------------------
  const payload = args['payload'] || {};
  if (payload.constructor === FormData) {
    
    params['data']        = payload;
    params['contentType'] = false;
    params['processData'] = false;
    
  } else {
    
    params['data']        = JSON.stringify(payload);
    params['contentType'] = "application/json";
    params['dataType']    = "json";
  }
  
  
  //-------------------------------------------------------
  // Begin async processing with custom callbacks.
  //-------------------------------------------------------
  xhr = $.ajax(params);
  
  if (args['onSuccess']) { xhr.done(args['onSuccess']);   }
  if (args['onFinally']) { xhr.always(args['onFinally']); }
  if (args['onError'])   { xhr.fail(args['onError']);     }
  
  return xhr;
}




function raise_error (data_api, details) {
  
  let title    = null;
  let subtitle = null;
  let html     = null;
  
    try {
      
      details = jQuery.parseJSON( details );
      console.log("Parsed error details = " + JSON.stringify(details));
    
      title    = details['message'];
      subtitle = [data_api, details['errcode']].filter(n => n).join(" - ");
      
      html = '<div class="subtitle">in ' + subtitle + '</div>\n';
      for (let i = 0; i < details['dumps'].length; i++) {
        let dump   = details['dumps'][i]
        let legend = '<legend>' + dump['title'] + '</legend>';
        let code   = dump['code'];
         if (dump['lang'] != null) {
          code = hljs.highlight(code, {language: dump['lang']}).value;
        }
        let res = '<fieldset>' + legend + '<pre><code>' + code + '</code></pre></fieldset>\n'
        
        html = html + res;
      }
      
    } catch (error) {
      console.log("Raising error with details = " + details);
      title = "In " + data_api + ":";
      html  = "<code><pre style='text-align:left'>" + details + "</pre></code>";
    }
    
    let el = document.createElement("div");
        el.innerHTML = html;
      
    swal({
      title: title,
      icon: 'error',
      content: el,
      button: 'Dismiss'
    })
    
  }
  
  
  function simple_error (title) {
    swal({
      title: title,
      icon: 'error',
      button: 'Dismiss'
    })
  }
  
  
