


//___________________________________________________________________
// Import projects from old version of atima.
//___________________________________________________________________
async function migrate_projects() {

  const q = get_value(['CONF', 'migration_queue']);
  const u = get_value(['CONF', 'user_id']); // abort migration if user_id changes
  
  if (q && q.length > 0) {
  	
  	swal({
      title: "Importing Projects",
      text: q[0]['title'],
      buttons: "Hide",
      closeOnEsc: false,
      closeOnClickOutside: false
    });
    
    // Add a progress bar to the modal
    $('<div class="meter" style="width:calc(100% - 120px); margin:25px 50px 10px"><span id="migrate_progress" style="width:0"></span></div>').insertAfter('.swal-text');
    
    for (let i = 0; i < q.length && u === get_value(['CONF', 'user_id']); i++) {
      
      let pb = $('#migrate_progress');
      if (pb) {
        $('.swal-text').text(q[i]['title']);
        pb.css('width', Math.floor(100 * (i / q.length)) + "%");
      }
      
      await api({
        'method'    : "migrate_project",
        'global'    : false,
        'payload'   : {
          'project_id' : q[i]['project_id'],
          'key'        : q[i]['key']
        },
        'onSuccess' : function (resp) {
          if (resp['node']) {
            $("#private_collections").jstree("create_node", '#', resp['node']);
          } else {
            console.log("Failed to import project_id " + q[i]['project_id']);
          }
        }
      });
    }
		
		if ($('#migrate_progress') && u === get_value(['CONF', 'user_id'])) { swal.close(); }
  }
}
