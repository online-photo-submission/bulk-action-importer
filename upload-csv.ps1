param (
    [Parameter(Mandatory=$true)] [string] $IMPORT_DIRECTORY,
    [Parameter(Mandatory=$true)][string] $FILE,
    [Parameter(Mandatory=$true)][string] $API_URL,
    [Parameter(Mandatory=$true)][string] $SESSION_TOKEN,
    [Parameter(Mandatory=$false)][string] $ACTION_DEFAULT
    #[Parameter(Mandatory=$false)[string] $COLUMN_NAMES
)

$ABSOLUTE_PATH = $IMPORT_DIRECTORY+ "\" + $FILE

$URL = $API_URL + "/bulk-action"

curl.exe --location $URL --header "X-Auth-Token: $SESSION_TOKEN" --form "csv=@$ABSOLUTE_PATH" --form "actionDefault=$ACTION_DEFAULT"

# To allow custom column names to the curl above (and uncomment the parameter on in the params map at the top of this script)
#--form "columnNames=$COLUMN_NAMES"
