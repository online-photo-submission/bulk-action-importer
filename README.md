# bulk-action-importer
This project is intended as a template for creating bash/powershell scripts for automatically uploading bulk action CSV files to the [RemotePhoto](https://remotephoto.ai/) bulk action API endpoint.

> [!IMPORTANT]
> CloudCard actively maintains this project and keeps it fully compatible with all RemotePhoto environments, including those managed by our partners.
> However, using this project is not directly supported by CloudCard or any partner unless your contract specifically includes it.

### Network Diagram
![Network Diagram](http://online-photo-submission.github.io/bulk-action-importer/network-diagram.jpg)

### See also the following CloudCard Documentation:
- User's Guide:
    - [Bulk Import/Create Cardholders](https://sharptop.atlassian.net/wiki/spaces/CCD/pages/24903725/Bulk+Import+Create+Cardholders)
    - [Bulk Action CSV Format](https://sharptop.atlassian.net/wiki/spaces/CCD/pages/2512879626/Bulk+Action+CSV+Format)
- Developer's Guide:
    - [Bulk Action](https://sharptop.atlassian.net/wiki/spaces/CCD/pages/2509176833/Bulk+Action)

## Installation and Configuration
- Download the [zip file](https://github.com/online-photo-submission/bulk-action-importer/archive/refs/heads/main.zip).
- Create a separate service account for CloudCard CSV importer and generate a Persistent Access Token ([Tutorial](https://www.youtube.com/watch?v=_J9WKAMZOdY)).
- Configure `config.sh` (Mac & Linux) OR `config.ps1` (Windows)
    - If you are on a Mac/Linux, delete all irrelevant `.ps1` files
    - If you are on a Windows, delete all irrelevant `.sh` files

## Configuration Settings
Modify the values in `config.sh`.  Some changes, such as explicitly specifying column names, also require changes to the `curl` command in `upload-csv.sh`.

- `IMPORT_DIRECTORY`
    - The directory containing the csv files that are going to upload into RemotePhoto (*Provide the absolute path*)
- `DONE_DIRECTORY`
    - The directory containing the csv files that have been uploaded to RemotePhoto (*Provide the absolute path*)
- `API_URL`
    - description: This option allows you to specify the URL of your RemotePhoto API.
        - default: `https://api.onlinephotosubmission.com`
        - Canadian customers should use `https://api.cloudcard.ca/`
        - Test Instance: `https://test-api.onlinephotosubmission.com/`
        - Transact Customers: `https://onlinephoto-api.transactcampus.net/`
- `PERSISTENT_ACCESS_TOKEN`
    - description: This setting holds the API access token for your service account. This must be set before the importer runs.
- `ACTION_DEFAULT`
    - `CREATE`
        - Provisions users with a unique identifier, while ignoring those who already have one.
    - `UPDATE`
        - Updates data for all existing users, while ignoring those with non-existent identifiers.
    - `CREATE_OR_UPDATE`
        - Create person or update them if they already exist.
    - `ARCHIVE`
        - Keeps the user's data but marks them inactive.
    - `RESTORE`
        - Change the user to an active state.
    - `ANONYMIZE`
        - Removes the user's data but keeps the photo record.
    - `DELETE`
        - Removes all user's data.
- `COLUMN_NAMES`
    - default:`email, identifier`
    - To pass in additional columns uncomment the relevant `COLUMN_NAMES` references in `upload-csv.sh` (Mac & Linux) OR `upload-csv.ps1` (Windows) file.
        - `upload-csv.ps1`
            - `--form "columnNames=$COLUMN_NAMES"`
            - `[Parameter(Mandatory=$false)[string] $COLUMN_NAMES`
            - `[Parameter(Mandatory=$false)][string] $ACTION_DEFAULT`
                - Add a comma at the end of the above line
        - `upload-csv.sh` (Add the following lines to the curl command)
            - `--form "fieldSeparator=|"`
            - `--form "columnNames=$COLUMN_NAMES"`
            - `--form "actionDefault=\"$ACTION_DEFAULT\""`

## Running Script
- Navigate to the bulk importer directory
    - `cd C:\Path\To\Your\Folder`

- Run the script file, importer.sh (Mac & Linux) OR importer.ps1 (Windows)
    - Mac/Linux `./importer.sh`
    - Windows `./importer.ps1`
        - Run if you get permissions block
            - `Set-ExecutionPolicy RemoteSigned -Scope LocalMachine`
            - Run to confirm it worked `Get-ExecutionPolicy -List`

