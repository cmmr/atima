# atima

**Agile Toolkit for Incisive Microbiome Analyses**

## Environmental Variables

| Env. Variable    | Default Value                   | Purpose             |
|------------------|---------------------------------|---------------------|
| `ATIMA_DATA_DIR` | `tools::R_user_dir("atima")`    | Persistent Data     |
| `ATIMA_TEMP_DIR` | `file.path(tempdir(), "atima")` | Temporary Files     |
| `ATIMA_TIMEOUT`  | `"15 minutes"`                  | Max Request Runtime |

### Email Sending

*Optional.* To verify user email addresses and reset forgotten passwords.

| Env. Variable         | Example Value                                    |
|-----------------------|--------------------------------------------------|
| `ATIMA_SMTP_SERVER`   | `"email-smtp.us-east-1.amazonaws.com"`           |
| `ATIMA_SMTP_PORT`     | `"465"`                                          |
| `ATIMA_SMTP_USERNAME` | `"<your-smtp-username>"`                         |
| `ATIMA_SMTP_PASSWORD` | `"<your-smtp-password>"`                         |
| `ATIMA_SMTP_SSL`      | `"true"`                                         |
| `ATIMA_SMTP_FROMADDR` | `"atima@example.org"`                            |
