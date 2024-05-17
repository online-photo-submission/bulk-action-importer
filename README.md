# bulk-action-importer
This project is intended as a template for creating bash/powershell scripts for automatically uploading bulk action CSV files to the [CloudCard Online Photo Submission](https://onlinephotosubmission.com/) bulk action API endpoint.

> [!IMPORTANT]
> CloudCard actively maintains this project and keeps it fully compatible with all CloudCard Online Photo Submission environments, including those managed by our partners.
> However, using this project is not directly supported by CloudCard or any partner unless your contract specifically includes it.

### Network Diagram
![Network Diagram](http://online-photo-submission.github.io/bulk-action-importer/network-diagram.jpg)

### See also the following CloudCard Documentation:
- User's Guide: 
  - [Bulk Import/Create Cardholders](https://sharptop.atlassian.net/wiki/spaces/CCD/pages/24903725/Bulk+Import+Create+Cardholders)
  - [Bulk Action CSV Format](https://sharptop.atlassian.net/wiki/spaces/CCD/pages/2512879626/Bulk+Action+CSV+Format)
- Developer's Guide:
  - [Bulk Action](https://sharptop.atlassian.net/wiki/spaces/CCD/pages/2509176833/Bulk+Action)

## Configuration
Modify the values in `config.sh`.  Some changes, such as explicitly specifying column names, also require changes to the `curl` command in `upload-csv.sh`.
