# bulk-action-importer
This project is intended as a template for creating a shell/batch script that will upload bulk action CSV files to the [CloudCard Online Photo Submission](https://onlinephotosubmission.com/) bulk action API endpoint.

### See also the following CloudCard Documentation:
- User's Guide: 
  - [Bulk Import/Create Cardholders](https://sharptop.atlassian.net/wiki/spaces/CCD/pages/24903725/Bulk+Import+Create+Cardholders)
  - [Bulk Action CSV Format](https://sharptop.atlassian.net/wiki/spaces/CCD/pages/2512879626/Bulk+Action+CSV+Format)
- Developer's Guide:
  - [Bulk Action](https://sharptop.atlassian.net/wiki/spaces/CCD/pages/2509176833/Bulk+Action)

## Configuration
Modify the values in `config.sh`.  Some changes, such as explicitly specifying column names, also require changes to the `curl` command in `upload-csv.sh`.
