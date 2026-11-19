// The Insights app's functions (Fabric Apps functions: server-side TypeScript that runs as the app item's owner).
// This file only registers them; each feature keeps its function in its own file.
// https://learn.microsoft.com/fabric/apps/functions
import { UserDataFunctions } from "@microsoft/fabric-user-data-functions";

import { registerEstate } from "./estate.js";
import { registerManage } from "./manage.js";

const udf = new UserDataFunctions();

registerEstate(udf);
registerManage(udf);