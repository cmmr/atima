
#______________________________________________________________________________
#' Send an email for email verifications, password resets, etc.
#' 
send_email <- function (REQ, to, subject, message) {
  tryCatch(
    error = function (e) stop("Unable to send email.", e),
    expr  = {
      
      SMTP     <- REQ[['SMTP']]
      TEMP_DIR <- REQ[['CONFIG']][['temp_dir']]
      
      #________________________________________________________
      # Coerce SSL value into 'true' or 'false'.
      #________________________________________________________
      if (!isTRUE(SMTP[['ssl']] %in% c('true', 'false'))) {
        SMTP[['ssl']] <- tolower(ssl) %in% c("1", "true", "yes", "on", "enabled")
        SMTP[['ssl']] <- ifelse(isTRUE(SMTP[['ssl']]), 'true', 'false')
      }
      
      
      #________________________________________________________
      # Blastula wants to read credentials from a json file.
      #________________________________________________________
      creds <- paste0(
        '{',
          '"type":"list",',
          '"attributes":{',
            '"names":{',
              '"type":"character",',
              '"attributes":{},',
              '"value":["version","host","port","use_ssl","user","password"]}},',
          '"value":[',
            '{"type":"integer","attributes":{},"value":[1]},',
            '{"type":"character","attributes":{},"value":["', SMTP[['server']],   '"]},',
            '{"type":"double","attributes":{},"value":[',     SMTP[['port']],     ']},',
            '{"type":"logical","attributes":{},"value":[',    SMTP[['ssl']],      ']},',
            '{"type":"character","attributes":{},"value":["', SMTP[['username']], '"]},',
            '{"type":"character","attributes":{},"value":["', SMTP[['password']], '"]}]}\n' )
      
      creds_file <- tempfile(tmpdir = TEMP_DIR)
      on.exit(unlink(creds_file))
      writeChar(con = creds_file, object = creds, eos = NULL)
      creds <- blastula::creds_file(file = creds_file)
      
      
      #________________________________________________________
      # Ensure message is a proper blastula object.
      #________________________________________________________
      if (!is(message, 'blastula_message')) {
        footer  <- blastula::md("sent by the [atima](https://cmmr.github.io/atima) R package")
        message <- blastula::compose_email(body = message, footer = footer)
      }
      
      
      #________________________________________________________
      # Transmit the message.
      #________________________________________________________
      blastula::smtp_send(
          email       = message,
          to          = to,
          from        = SMTP[['fromaddr']], 
          subject     = subject, 
          credentials = creds )
    })
}

