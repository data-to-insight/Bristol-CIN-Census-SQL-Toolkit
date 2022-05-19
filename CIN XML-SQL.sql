/* CIN import-export by Andrew Denner (a.denner@bristol.gov.uk)

	Overview
The starting point of this query is an import script for a CIN Census XML file.
The import script loads the data from the file into temporary tables, with the
same structure as the blades that can be exported from COLLECT. This code can be 
found between the "Section 1: IMPORT" start and end comments below.

Having these blades loaded into temporary tables on your database offers you
lots of interesting opportunities. You could write a query that summarises your
data for reporting to your service. You could store a copy of the data to 
permanent tables within your database. The choice is yours.

This script comes with two useful pre-prepared queries that make use of the blades.
"Section 2: ERROR CHECKING" replicates testing the data in the blades against the
DfE's validation rules for the CIN census. The rule violations are also stored in
temp tables, so that you can customise the output format. You might choose to add
extra columns from the blades, or join them to your reporting tables to add extra
identifying information like names and workers into the error list.

"Section 3: EXPORT" takes the blades, and reassembles them into the CIN XML format.
Unaltered, this should just reconstruct your input XML file. But there's potential
for it to be more useful if you make alterations to the data in the blade first,
for example inserting missing values or deleting incorrect records. Most drastic
of all, you could delete all the data in the tables and generate a whole new return.

Sections 2 & 3 are commented out by to start with, so you must decide which to run
and then uncomment the SQL code.

	Using the script
To run this script interactively in SSMS, you need to perform two steps of preparation.
First, type the path to the CIN XML file you want to load between the double quotes
on the following line:*/
:SETVAR INFILE "H:\CSC\CIN-Census\cin-export.xml"
/*
Next, go to the Query menu and turn SQLCMD Mode on. Finally, press Ctrl-D so that the
query results go to the grid. You can now execute the script.

    Additional tips for EXPORT
When you run Section 3 in SSMS, you should see a single cell in the results grid
with blue underlined text. Click that and the XML output will open in a new tab.

You can also run this script on the command line using SQLCMD.exe, and have it 
automatically save the XML output to a file. Use the following command line as a
template; the parts in [brackets] need to be replaced with values:

SQLCMD.exe -i [ScriptPath] -v INFILE=[InputPath] -o [OutputPath] -S [ServerName]

[ScriptPath]: PATH to this SQL file
[InputPath]: PATH to the original 903 XML file you wish to load
[OutputPath]: PATH to save the 903 XML output
[ServerName]: name of any SQL Server you can connect to
Put quotes around all paths containing spaces.

If you use a username and password to connect to [ServerName], add -U [Username]
to the end of the command line. SQLCMD.exe will prompt you for your password.

	Troubleshooting

If you get the error "Incorrect syntax near ':'" when running the script interactively,
you need to turn on SQLCMD mode.

	version History
v1(08/10/2019): initial version, for 2018-19 format output
v2: add the id columns for all the subqueries and sort on them to preserve output order of elements within lists!
v3(13/03/2020): change the rules around the FactorsIdentifiedAtAssessment tag to match LL approach:
                always output the tag if the assesment is finalised, even if there are no factors
                do not force the tag to be output if there are no factors (but permit it if there are factors on an unfinalised assessment - this would be a mistake in the input, but we want to copy it AS exactly AS possible)
v4(26/03/2021): correction by Joe.Meredith@n-somerset.gov.uk to handling of multiple ChildProtectionPlans elements in one CINDetails element
v5(27/01/2022): change the schema from 2022 onwards - omit the content section of the Header
v6(21/04/2022): build into a single script with temp tables and combined import/export steps
v7(29/04/2022): added steps between import and export to calculate validation checks for the file
*/



/************************* Section 1: IMPORT start *************************/

--This group of lines ensure that the command-line output is the complete XML file with no other messages
SET NOCOUNT ON
:XML ON
:setvar SQLCMDMAXVARTYPEWIDTH 0

--These lines import and parse the content of the input file
DECLARE @docHandle int;  
DECLARE @xmlDocument xml;
:setvar MAGICQUOTE "'"
SET @xmlDocument = 
$(MAGICQUOTE):r $(INFILE)
$(MAGICQUOTE);

EXEC sp_xml_preparedocument @docHandle OUTPUT, @xmlDocument;  

--these lines read the 'blades' FROM the XML file into temporary tables

SELECT *
INTO [#Stat_CIN_Child]
FROM OPENXML(@docHandle, N'/Message/Children/Child/ChildCharacteristics',2)
WITH (
	[Ethnicity] nvarchar(255), 
	--Have to backtrack and enter the ChildIdenfifiers tab for most of these
	--Chose to base the selection on the ChildCharacteristics tag because it is
	--the one that contains further tags (so we need the unique ID).
	[LAchildID] nvarchar(10) '../ChildIdentifiers/LAchildID',
	[UPN] nvarchar(255) '../ChildIdentifiers/UPN',
	[FormerUPN] nvarchar(255) '../ChildIdentifiers/FormerUPN',
	[UPNunknown] nvarchar(255) '../ChildIdentifiers/UPNunknown',
	[PersonBirthDate] date '../ChildIdentifiers/PersonBirthDate',
	[ExpectedPersonBirthDate] date '../ChildIdentifiers/ExpectedPersonBirthDate',
	[GenderCurrent] smallint '../ChildIdentifiers/GenderCurrent',
	[PersonDeathDate] date '../ChildIdentifiers/PersonDeathDate',
	[Child_XML_ID] int '@mp:parentid',
	[ChildCharacteristics_ID] int '@mp:id'
);

SELECT *   
INTO [#Stat_CIN_ChildProtectionPlans]
FROM OPENXML(@docHandle, N'/Message/Children/Child/CINdetails/ChildProtectionPlans',2)
WITH (
	[ChildProtectionPlans_ID] int '@mp:id',
	[CPPstartDate] date,
	[CPPendDate] date,
	[InitialCategoryOfAbuse] nvarchar(255),
	[LatestCategoryOfAbuse] nvarchar(255),
	[NumberOfPreviousCPP] int,
	[CINdetails_ID] int '@mp:parentid'
);

SELECT *
INTO [#Stat_CIN_CINdetails] 
FROM OPENXML(@docHandle, N'/Message/Children/Child/CINdetails',2)
WITH (
	[CINdetails_ID] int '@mp:id',
	[CINreferralDate] date,
	[ReferralSource] nvarchar(255),
	[PrimaryNeedCode] nvarchar(255),
	[CINclosureDate] date,
	[ReasonForClosure] nvarchar(255),
	[DateOfInitialCPC] date,
	[ReferralNFA] bit,
	[Child_XML_ID] int '@mp:parentid'
);

--In the next two cases we have to do some actual queries to join two "levels" of the file, because we need a higher level unique ID
--paired with the values at the lower level
WITH Disabilities as (
SELECT *   
FROM OPENXML(@docHandle, N'/Message/Children/Child/ChildCharacteristics/Disabilities/Disability',2)
WITH (
	[Disability] nvarchar(255) '.', --the PATH has to hit the granularity of the repeating tag, but we want the content of that tag!
	[Disabilities_ID] int '@mp:parentid'
)
)
,ChildCharacteristics as (
SELECT *   
FROM OPENXML(@docHandle, N'/Message/Children/Child/ChildCharacteristics/Disabilities',2)
WITH (
	[Disabilities_ID] int '@mp:id',
	[ChildCharacteristics_ID] int '@mp:parentid'
)
)
SELECT [ChildCharacteristics_ID], [Disability]
INTO [#Stat_CIN_Disability]
FROM Disabilities
INNER JOIN ChildCharacteristics
ON Disabilities.[Disabilities_ID] = ChildCharacteristics.[Disabilities_ID];

WITH Reviews AS (
SELECT [Review_ID],	[ChildProtectionPlans_ID]   
FROM OPENXML(@docHandle, N'/Message/Children/Child/CINdetails/ChildProtectionPlans/Reviews',2)
WITH (
	[Review_ID] int '@mp:id',
	[ChildProtectionPlans_ID] int  '@mp:parentid'
)
)
,Review_Dates AS (
SELECT [Review_ID],[CPPreviewDate]   
FROM OPENXML(@docHandle, N'/Message/Children/Child/CINdetails/ChildProtectionPlans/Reviews/CPPreviewDate',2)
WITH (
	[Review_ID] int '@mp:parentid',
	[CPPreviewDate] date '.'
)
)
SELECT Review_Dates.*, Reviews.[ChildProtectionPlans_ID]
INTO [#Stat_CIN_Reviews]
FROM Review_Dates inner join Reviews
ON Review_Dates.[Review_ID] = Reviews.[Review_ID]

SELECT *
INTO [#Stat_CIN_Assessments]
FROM OPENXML(@docHandle, N'/Message/Children/Child/CINdetails/Assessments',2)
WITH (
	[Assessments_ID] int '@mp:id',
	[AssessmentActualStartDate] date,
	[AssessmentInternalReviewDate] date,
	[AssessmentAuthorisationDate] date,
	[CINdetails_ID] int '@mp:parentid'
);

--Assessment factors involves a lengthy query for a two column output
WITH FactorsIdentifiedAtAssessment AS (
SELECT [FactorsIdentifiedAtAssessment_ID],	[Assessments_ID]   
FROM OPENXML(@docHandle, N'/Message/Children/Child/CINdetails/Assessments/FactorsIdentifiedAtAssessment',2)
WITH (
	[FactorsIdentifiedAtAssessment_ID] int '@mp:id',
	[Assessments_ID] int  '@mp:parentid'
    )
)
,Assessment_Factors AS (
SELECT [FactorsIdentifiedAtAssessment_ID],  [AssessmentFactors] 
FROM OPENXML(@docHandle, N'/Message/Children/Child/CINdetails/Assessments/FactorsIdentifiedAtAssessment/AssessmentFactors',2)
WITH (
	[FactorsIdentifiedAtAssessment_ID] int '@mp:parentid',
	[AssessmentFactors] nvarchar(255) '.' --the PATH has to hit the granularity of the repeating tag, but we want the content of that tag!
    )
)
SELECT [AssessmentFactors], [Assessments_ID]
INTO [#Stat_CIN_AssessmentFactors]
FROM FactorsIdentifiedAtAssessment inner join Assessment_Factors
ON FactorsIdentifiedAtAssessment.[FactorsIdentifiedAtAssessment_ID] = Assessment_Factors.[FactorsIdentifiedAtAssessment_ID]

SELECT *   
INTO [#Stat_CIN_Section47]
FROM OPENXML(@docHandle, N'/Message/Children/Child/CINdetails/Section47',2)
WITH (
	[S47ActualStartDate] date,
	[InitialCPCtarget] date,
	[DateOfInitialCPC] date,
	[ICPCnotRequired] bit,
	[Section47_ID] int '@mp:id',
	[CINdetails_ID] int '@mp:parentid'
);


WITH CollectionDetails AS (
SELECT [Collection],[Year],[ReferenceDate]  
FROM OPENXML(@docHandle, N'/Message/Header/CollectionDetails',2)
WITH (
	[Collection] nvarchar(255),
	[Year] int,
	[ReferenceDate] date
    )
),[Source] AS (
SELECT [SourceLevel],[LEA],[SoftwareCode],[Release],[SerialNo],[DateTime],[CBDSLevel]
FROM OPENXML(@docHandle, N'/Message/Header/Source',2)
WITH (
	[SourceLevel] nvarchar(255),
	[LEA] nvarchar(255),
	[SoftwareCode] nvarchar(255),
	[Release] nvarchar(255),
	[SerialNo] int,
    [DateTime] datetime,
	[CBDSLevel]	nvarchar(255)
    )
)
SELECT [Collection],[Year],[ReferenceDate], [SourceLevel],[LEA],[SoftwareCode],[Release],[SerialNo],[DateTime],[CBDSLevel]
INTO [#Stat_CIN_Header]
FROM [CollectionDetails]
CROSS JOIN [Source]

SELECT *
INTO [#Stat_CIN_Plans]
FROM OPENXML(@docHandle, N'/Message/Children/Child/CINdetails/CINPlanDates',2)
WITH (
	[CINPlanStartDate] date,
	[CINPlanEndDate] date,
	[CINPlan_Id] int '@mp:id',
	[CINdetails_Id] int  '@mp:parentid'
    )


EXEC sp_xml_removedocument @docHandle;


/************************* Section 1: IMPORT end *************************/


/************************* Section 2: ERROR CHECKING start *************************/
/*
create table #ErrorReturnLevel (ErrorNumber varchar(5), [Message] varchar(max))
create table #ErrorChildLevel (ErrorNumber varchar(5), [Message] varchar(max),[LAchildID] nvarchar(10),[UPN] nvarchar(255),[PersonBirthDate] date,[GenderCurrent] smallint,[Child_XML_ID] int)
create table #ErrorCINLevel (ErrorNumber varchar(5), [Message] varchar(max),[CINdetails_ID] int,[CINreferralDate] date,[CINclosureDate] date)
create table #ErrorAssessmentLevel (ErrorNumber varchar(5), [Message] varchar(max),[Assessments_ID] int,[AssessmentActualStartDate] date,[CINdetails_ID] int )
create table #ErrorCINPlanLevel (ErrorNumber varchar(5), [Message] varchar(max),[CINPlan_ID] int,[CINPlanStartDate] date,[CINdetails_ID] int )
create table #ErrorSection47Level (ErrorNumber varchar(5), [Message] varchar(max),[Section47_ID] int,[S47ActualStartDate] date,[CINdetails_ID] int )
create table #ErrorCPPLevel (ErrorNumber varchar(5), [Message] varchar(max),[ChildProtectionPlans_ID] int,[CPPstartDate] date,[CINdetails_ID] int )


declare @CensusStartDate date = '20210401';
declare @CensusEndDate date = '20220331';
--header/return level

INSERT #ErrorReturnLevel
select '100' as ErrorNumber, 'Reference Date is incorrect' as [Message]
from [#Stat_CIN_Header] where ReferenceDate is null or ReferenceDate <> @CensusEndDate

INSERT #ErrorReturnLevel
select '2883' as ErrorNumber, 'There are more child protection plans starting than initial conferences taking place' as [Message]
where (
 select count(*) from [#Stat_CIN_ChildProtectionPlans] where [CPPstartDate] between @CensusStartDate and @CensusEndDate
) > (
 select count(*) from [#Stat_CIN_CINDetails] where DateOfInitialCPC between @CensusStartDate and @CensusEndDate
) + (
 select count(*) from [#Stat_CIN_Section47] where DateOfInitialCPC between @CensusStartDate and @CensusEndDate
)

INSERT #ErrorReturnLevel
select '2883' as ErrorNumber, 'There are more child protection plans starting than initial conferences taking place' as [Message]
where (
 select count(*) from [#Stat_CIN_ChildProtectionPlans] where [CPPstartDate] between @CensusStartDate and @CensusEndDate
) > (
 select count(*) from [#Stat_CIN_CINDetails] where DateOfInitialCPC between @CensusStartDate and @CensusEndDate
) + (
 select count(*) from [#Stat_CIN_Section47] where DateOfInitialCPC between @CensusStartDate and @CensusEndDate
)

INSERT #ErrorReturnLevel
select '2886Q' as ErrorNumber, 'Please check: Percentage of children with no gender recorded is more than 2% (excluding unborns)' as [Message]
from [#Stat_CIN_Child]
having (count(case when ([GenderCurrent] is null or [GenderCurrent] = 0) 
and [ExpectedPersonBirthDate] is null then 1 end) * 50)  > count(*)

INSERT #ErrorReturnLevel
select '2887Q' as ErrorNumber, 'Please check: Less than 8 disability codes have been used in your return' as [Message]
from [#Stat_CIN_Disability] where Disability <> 'NONE'
having count(distinct Disability) <= 7

INSERT #ErrorReturnLevel
select '2888Q' as ErrorNumber, 'Please check: Only one disability code is recorded per child and multiple disabilities should be recorded where possible.' as [Message]
where not exists (
select 1 
from [#Stat_CIN_Disability]
where Disability <> 'NONE'
group by [ChildCharacteristics_ID]
having count(*) > 1
)

--Child Level
INSERT #ErrorChildLevel
select '8500','LA Child ID missing', [LAchildID],[UPN],[PersonBirthDate],[GenderCurrent],[Child_XML_ID]
from [#Stat_CIN_Child] where LAchildID is null

INSERT #ErrorChildLevel
select '8510','More than one child record with the same LA Child ID', [LAchildID],[UPN],[PersonBirthDate],[GenderCurrent],[Child_XML_ID]
from (select count(*) over (partition by [LAchildID]) [LAchildIDCount],*
from [#Stat_CIN_Child] where [LAchildID] is not null) child_count
where [LAchildIDCount]> 1

INSERT #ErrorChildLevel
SELECT ErrorCode, ErrorDesc, [LAchildID],[UPN],[PersonBirthDate],[GenderCurrent],[Child_XML_ID]
from [#Stat_CIN_Child]
CROSS APPLY (
SELECT UPN as TestUPN , '1510' as ErrorCode,'UPN invalid (wrong check letter at character 1)' as ErrorDesc
UNION ALL
SELECT FormerUPN as TestUPN , '1560Q' as ErrorCode,'Please check:  Former UPN wrongly formatted' as ErrorDesc
) split
CROSS APPLY (SELECT UPPER(LEFT(UPN,1)) Initial, SUBSTRING(UPN,2,11) Mid, UPPER(RIGHT(UPN,1)) Final ) t1
CROSS APPLY (SELECT case when Initial BETWEEN 'A' AND 'H' then ASCII(Initial) - ASCII('A')
						 when Initial BETWEEN 'J' AND 'N' then ASCII(Initial) - ASCII('B')
						 when Initial BETWEEN 'P' AND 'R' then ASCII(Initial) - ASCII('C')
						 when Initial BETWEEN 'T' AND 'Z' then ASCII(Initial) - ASCII('D') end as InitialCode
			 ,case when ISNUMERIC(Mid) = 1 then Mid end as TrueDigits
			 ,case when Final BETWEEN '0' AND '9' then ASCII(Final) - ASCII('0')
				   when Final BETWEEN 'A' AND 'H' then ASCII(Final) - ASCII('A')
				   when Final BETWEEN 'J' AND 'N' then ASCII(Final) - ASCII('B')
				   when Final BETWEEN 'P' AND 'R' then ASCII(Final) - ASCII('C')
				   when Final BETWEEN 'T' AND 'Z' then ASCII(Final) - ASCII('D') end as FinalCode
			 ) t2
CROSS APPLY (SELECT (SUBSTRING(TrueDigits,1,1) * 2) % 23 d1,(SUBSTRING(TrueDigits,2,1) * 3) % 23 d2
			 ,(SUBSTRING(TrueDigits,3,1) * 4) % 23 d3,(SUBSTRING(TrueDigits,4,1) * 5) % 23 d4
			 ,(SUBSTRING(TrueDigits,5,1) * 6) % 23 d5,(SUBSTRING(TrueDigits,6,1) * 7) % 23 d6
			 ,(SUBSTRING(TrueDigits,7,1) * 8) % 23 d7,(SUBSTRING(TrueDigits,8,1) * 9) % 23 d8
			 ,(SUBSTRING(TrueDigits,9,1) * 10) % 23 d9,(SUBSTRING(TrueDigits,10,1) * 11) % 23 d10
			 ,(SUBSTRING(TrueDigits,11,1) * 12) % 23 d11,(FinalCode * 13) % 23 d12
			 ) t3
CROSS APPLY(SELECT (d1+d2+d3+d4+d5+d6+d7+d8+d9+d10+d11+d12) % 23 as [Checksum]) t4
WHERE TestUPN is not null and ([Checksum] is null or InitialCode is null or InitialCode <> [Checksum])

INSERT #ErrorChildLevel
select '1520','More than one record with the same UPN', [LAchildID],[UPN],[PersonBirthDate],[GenderCurrent],[Child_XML_ID]
from (select count(*) over (partition by [UPN]) [LAchildIDCount],*
from [#Stat_CIN_Child] where [UPN] is not null) child_count
where [LAchildIDCount]> 1

INSERT #ErrorChildLevel
SELECT '1530','UPN invalid (characters 2-4 not a recognised LA code)', [LAchildID],[UPN],[PersonBirthDate],[GenderCurrent],[Child_XML_ID]
from [#Stat_CIN_Child] CROSS APPLY(SELECT SUBSTRING([UPN],2,3) AS UPN_LA) t1
WHERE UPN_LA NOT BETWEEN '001' AND '005'
  AND UPN_LA NOT BETWEEN '201' AND '213'
  AND UPN_LA NOT BETWEEN '301' AND '320'
  AND UPN_LA NOT BETWEEN '330' AND '336'
  AND UPN_LA NOT BETWEEN '340' AND '344'
  AND UPN_LA NOT BETWEEN '350' AND '359'
  AND UPN_LA NOT BETWEEN '370' AND '373'
  AND UPN_LA NOT BETWEEN '380' AND '384'
  AND UPN_LA NOT BETWEEN '390' AND '394'
  AND UPN_LA NOT BETWEEN '660' AND '681'
  AND UPN_LA NOT BETWEEN '701' AND '708'
  AND UPN_LA NOT BETWEEN '800' AND '803'
  AND UPN_LA NOT BETWEEN '805' AND '808'
  AND UPN_LA NOT BETWEEN '810' AND '813'
  AND UPN_LA NOT BETWEEN '820' AND '823'
  AND UPN_LA NOT BETWEEN '835' AND '837'
  AND UPN_LA NOT BETWEEN '838' AND '839'
  AND UPN_LA NOT BETWEEN '850' AND '852'
  AND UPN_LA NOT BETWEEN '855' AND '857'
  AND UPN_LA NOT BETWEEN '865' AND '896'
  AND UPN_LA NOT BETWEEN '935' AND '938'
  AND UPN_LA NOT BETWEEN '940' AND '941'
  AND UPN_LA NOT IN ('420', '815', '816', '825', '826', '830', '831', '840', '841', '845', '846', '860', '861', '908', '909', '916', '919', '921', '925', '926', '928', '929', '931', '933') 
  
INSERT #ErrorChildLevel
SELECT '1540','UPN invalid (characters 5-12 not all numeric)', [LAchildID],[UPN],[PersonBirthDate],[GenderCurrent],[Child_XML_ID]
from [#Stat_CIN_Child]
WHERE ISNUMERIC(SUBSTRING(UPN,2,11)) = 0 and UPN is not null

INSERT #ErrorChildLevel
SELECT '1550','UPN invalid (characters 5-12 not all numeric)', [LAchildID],[UPN],[PersonBirthDate],[GenderCurrent],[Child_XML_ID]
from [#Stat_CIN_Child] CROSS APPLY (SELECT UPPER(RIGHT(UPN,1)) Final ) t1
WHERE Final NOT BETWEEN '0' AND '9' 
  AND Final NOT BETWEEN 'A' AND 'H'
  AND Final NOT BETWEEN 'J' AND 'N'
  AND Final NOT BETWEEN 'P' AND 'R'
  AND Final NOT BETWEEN 'T' AND 'Z'

INSERT #ErrorChildLevel
SELECT '1550','UPN invalid (characters 5-12 not all numeric)', [LAchildID],[UPN],[PersonBirthDate],[GenderCurrent],[Child_XML_ID]
from [#Stat_CIN_Child] CROSS APPLY (SELECT UPPER(RIGHT(UPN,1)) Final ) t1
WHERE Final NOT BETWEEN '0' AND '9' 
  AND Final NOT BETWEEN 'A' AND 'H'
  AND Final NOT BETWEEN 'J' AND 'N'
  AND Final NOT BETWEEN 'P' AND 'R'
  AND Final NOT BETWEEN 'T' AND 'Z'


INSERT #ErrorChildLevel
SELECT '1550','UPN invalid (characters 5-12 not all numeric)', [LAchildID],[UPN],[PersonBirthDate],[GenderCurrent],[Child_XML_ID]
from [#Stat_CIN_Child] CROSS APPLY (SELECT UPPER(RIGHT(UPN,1)) Final ) t1
WHERE Final NOT BETWEEN '0' AND '9' 
  AND Final NOT BETWEEN 'A' AND 'H'
  AND Final NOT BETWEEN 'J' AND 'N'
  AND Final NOT BETWEEN 'P' AND 'R'
  AND Final NOT BETWEEN 'T' AND 'Z'
--1560Q done earlier

INSERT #ErrorChildLevel
SELECT '8520','Date of Birth is after data collection period (must be on or before the end of the census period)', [LAchildID],[UPN],[PersonBirthDate],[GenderCurrent],[Child_XML_ID]
from [#Stat_CIN_Child]
WHERE [PersonBirthDate] > @CensusEndDate

INSERT #ErrorChildLevel
SELECT '8770Q','Please check: UPN or reason UPN missing expected for a child who is more than 5 years old', [LAchildID],[UPN],[PersonBirthDate],[GenderCurrent],ch.[Child_XML_ID]
from [#Stat_CIN_Child] ch inner join [#Stat_CIN_CINDetails] cin on ch.[Child_XML_ID] = cin.[Child_XML_ID]
WHERE DATEADD(YEAR, 6, [PersonBirthDate]) <= @CensusEndDate
AND ReferralNFA = 0
AND UPN is null and (UPNunknown is null or UPNunknown not in ('UN2','UN3','UN4','UN5','UN6'))--UN1 and UN7 not applicable

INSERT #ErrorChildLevel
SELECT '8772','UPN unknown reason is UN7 (Referral with no further action) but at least one CIN details is a referral going on to further action ', [LAchildID],[UPN],[PersonBirthDate],[GenderCurrent],ch.[Child_XML_ID]
from [#Stat_CIN_Child] ch 
WHERE UPNunknown='UN7'
AND EXISTS (SELECT 1 FROM [#Stat_CIN_CINDetails] cin 
WHERE ch.[Child_XML_ID] = cin.[Child_XML_ID] and (ReferralNFA <> 1 or ReferralNFA is null))

INSERT #ErrorChildLevel
SELECT '8775Q','Please check:  Child is over 25 years old', [LAchildID],[UPN],[PersonBirthDate],[GenderCurrent],ch.[Child_XML_ID]
from [#Stat_CIN_Child] ch
WHERE DATEADD(YEAR, 25, [PersonBirthDate]) < @CensusEndDate
AND EXISTS (SELECT 1 FROM [#Stat_CIN_CINDetails] cin 
WHERE ch.[Child_XML_ID] = cin.[Child_XML_ID]
AND (cin.CINClosureDate IS NULL OR DATEADD(YEAR, 25, [PersonBirthDate]) < cin.CINClosureDate)
)

INSERT #ErrorChildLevel
SELECT '8525','Either Date of Birth or Expected Date of Birth must be provided (but not both)', [LAchildID],[UPN],[PersonBirthDate],[GenderCurrent],ch.[Child_XML_ID]
from [#Stat_CIN_Child] ch
WHERE ([PersonBirthDate] IS NULL AND [ExpectedPersonBirthDate] IS NULL)
OR  ([PersonBirthDate] IS NOT NULL AND [ExpectedPersonBirthDate] IS NOT NULL)

INSERT #ErrorChildLevel
SELECT '8530Q','Please check:  Expected Date of Birth is outside the expected range for this census (March to December of the Census Year end)', [LAchildID],[UPN],[PersonBirthDate],[GenderCurrent],ch.[Child_XML_ID]
from [#Stat_CIN_Child] ch
WHERE [ExpectedPersonBirthDate] < DATEADD(DAY, -30, @CensusEndDate)
OR [ExpectedPersonBirthDate] > DATEADD(MONTH, 9, @CensusEndDate)

INSERT #ErrorChildLevel
SELECT '4180','Gender is missing', [LAchildID],[UPN],[PersonBirthDate],[GenderCurrent],ch.[Child_XML_ID]
from [#Stat_CIN_Child] ch
WHERE [GenderCurrent] IS NULL OR [GenderCurrent] NOT IN (0,1,2,9)

INSERT #ErrorChildLevel
SELECT '8750','Gender must equal 0 for an unborn child', [LAchildID],[UPN],[PersonBirthDate],[GenderCurrent],ch.[Child_XML_ID]
from [#Stat_CIN_Child] ch
WHERE [ExpectedPersonBirthDate] IS NOT NULL AND [GenderCurrent] <> 0

INSERT #ErrorChildLevel
SELECT '8535Q','Please check: Child’s date of death should not be prior to the date of birth', [LAchildID],[UPN],[PersonBirthDate],[GenderCurrent],ch.[Child_XML_ID]
from [#Stat_CIN_Child] ch
WHERE [PersonDeathDate] < [PersonBirthDate] OR ([PersonDeathDate] IS NOT NULL AND [PersonBirthDate] IS NULL)

INSERT #ErrorChildLevel
SELECT '8545Q','Please check: Child’s date of death should be within the census year', [LAchildID],[UPN],[PersonBirthDate],[GenderCurrent],ch.[Child_XML_ID]
from [#Stat_CIN_Child] ch
WHERE [PersonDeathDate] > @CensusEndDate OR  [PersonDeathDate] < @CensusStartDate

INSERT #ErrorChildLevel
SELECT '4220','Ethnicity is missing or invalid (see Ethnicity table)', [LAchildID],[UPN],[PersonBirthDate],[GenderCurrent],ch.[Child_XML_ID]
from [#Stat_CIN_Child] ch
WHERE [Ethnicity] IS NULL OR [Ethnicity] NOT IN ('ABAN','AIND','AOTH','APKN','BAFR','BCRB','BOTH',
'CHNE','MOTH','MWAS','MWBA','MWBC','NOBT','OOTH','REFU','WBRI','WIRI','WIRT','WOTH','WROM')

INSERT #ErrorChildLevel
SELECT '8540','Child’s disability is missing or invalid (see Disability table)', [LAchildID],[UPN],[PersonBirthDate],[GenderCurrent],ch.[Child_XML_ID]
from [#Stat_CIN_Child] ch
WHERE [PersonBirthDate] IS NOT NULL
AND EXISTS (SELECT 1 FROM [#Stat_CIN_CINDetails] cin 
WHERE ch.[Child_XML_ID] = cin.[Child_XML_ID]
AND ReferralNFA = 0
)
AND (
    NOT EXISTS (SELECT 1 from [#Stat_CIN_Disability] d where d.ChildCharacteristics_ID = ch.ChildCharacteristics_ID)
    OR EXISTS (SELECT 1 from [#Stat_CIN_Disability] d where d.ChildCharacteristics_ID = ch.ChildCharacteristics_ID 
              AND [Disability] NOT IN ('AUT','BEH','COMM','CON','DDA','HAND','HEAR','INC','LD','MOB','PC','VIS','NONE'))
)

INSERT #ErrorChildLevel
SELECT '8790','Disability information includes both None and other values', [LAchildID],[UPN],[PersonBirthDate],[GenderCurrent],ch.[Child_XML_ID]
from [#Stat_CIN_Child] ch INNER JOIN [#Stat_CIN_Disability] d_none ON d_none.ChildCharacteristics_ID = ch.ChildCharacteristics_ID AND d_none.[Disability]='NONE'
WHERE [PersonBirthDate] IS NOT NULL
AND EXISTS (SELECT 1 from [#Stat_CIN_Disability] d where d.ChildCharacteristics_ID = ch.ChildCharacteristics_ID AND [Disability] <> 'NONE')


INSERT #ErrorChildLevel
SELECT '8794','Child has two or more disabilities with the same code', [LAchildID],[UPN],[PersonBirthDate],[GenderCurrent],ch.[Child_XML_ID]
from [#Stat_CIN_Child] ch INNER JOIN
(SELECT ChildCharacteristics_ID FROM [#Stat_CIN_Disability] 
GROUP BY ChildCharacteristics_ID
HAVING COUNT(DISTINCT [Disability]) < COUNT([Disability])
) d ON d.ChildCharacteristics_ID = ch.ChildCharacteristics_ID

INSERT #ErrorChildLevel
SELECT '8590','Child does not have a recorded CIN episode.', [LAchildID],[UPN],[PersonBirthDate],[GenderCurrent],ch.[Child_XML_ID]
from [#Stat_CIN_Child] ch
WHERE NOT EXISTS (SELECT 1 FROM [#Stat_CIN_CINDetails] cin 
WHERE ch.[Child_XML_ID] = cin.[Child_XML_ID]
)

INSERT #ErrorCINLevel
SELECT '8606','Child referral date is more than 40 weeks before DOB or expected DOB',[CINDetails_ID], [CINreferralDate], [CINclosureDate]
FROM [#Stat_CIN_CINDetails] cin
INNER JOIN [#Stat_CIN_Child] ch ON ch.[Child_XML_ID] = cin.[Child_XML_ID]
WHERE DATEADD(DAY,-280, ch.[PersonBirthDate]) > [CINreferralDate]
OR DATEADD(DAY,-280, ch.[ExpectedPersonBirthDate]) > [CINreferralDate]

INSERT #ErrorCINLevel
SELECT '8555','Child cannot be referred after its recorded date of death',[CINDetails_ID], [CINreferralDate], [CINclosureDate]
FROM [#Stat_CIN_CINDetails] cin
INNER JOIN [#Stat_CIN_Child] ch ON ch.[Child_XML_ID] = cin.[Child_XML_ID]
WHERE ch.[PersonDeathDate] < cin.[CINreferralDate]

INSERT #ErrorCINLevel
SELECT '8610','Primary Need code is missing for a referral which led to further action',[CINDetails_ID], [CINreferralDate], [CINclosureDate]
FROM [#Stat_CIN_CINDetails] cin
WHERE ReferralNFA = 0 AND PrimaryNeedCode IS NULL

INSERT #ErrorCINLevel
SELECT '8650','Primary Need Code invalid (see Primary Need table in CIN census code set)',[CINDetails_ID], [CINreferralDate], [CINclosureDate]
FROM [#Stat_CIN_CINDetails] cin
WHERE PrimaryNeedCode NOT IN ('N1','N2','N3','N4','N5','N6','N7','N8','N9') --N0?

INSERT #ErrorCINLevel
SELECT '8866','Source of Referral is missing or an invalid code',[CINDetails_ID], [CINreferralDate], [CINclosureDate]
FROM [#Stat_CIN_CINDetails] cin
WHERE [CinReferralDate] > '20130331' AND (ReferralSource IS NULL OR ReferralSource NOT IN ('1A','1B','1C','1D','2A',
'2B','3A','3B','3C','3D','3E','3F','4','5A','5B','5C','6','7','8','9','10'))

SET DATEFIRST 1
DECLARE @PrevWorkingDay date = DATEADD(DAY, -1, @CensusStartDate) --Start with the previous day
SET @PrevWorkingDay = CASE WHEN DATEPART(WEEKDAY,@PrevWorkingDay) in (6,7) -- Move it back more if it's Saturday or Sunday
     THEN DATEADD(DAY, 5 - DATEPART(WEEKDAY,@PrevWorkingDay),@PrevWorkingDay)
	 ELSE @PrevWorkingDay END
	 
INSERT #ErrorCINLevel
SELECT '8569','A case with referral date before one working day prior to the collection start date must not be flagged as a no further action case',[CINDetails_ID], [CINreferralDate], [CINclosureDate]
FROM [#Stat_CIN_CINDetails] cin
WHERE [CINreferralDate] < @PrevWorkingDay and ReferralNFA <> 0

INSERT #ErrorCINLevel
SELECT '8620','CIN Closure Date present and does not fall within the Census year',[CINDetails_ID], [CINreferralDate], [CINclosureDate]
FROM [#Stat_CIN_CINDetails] cin
WHERE [CINclosureDate] < @CensusStartDate or [CINclosureDate] > @CensusEndDate

INSERT #ErrorCINLevel
SELECT '8630','CIN Closure Date is before CIN Referral Date for the same CIN episode',[CINDetails_ID], [CINreferralDate], [CINclosureDate]
FROM [#Stat_CIN_CINDetails] cin
WHERE [CINclosureDate] < [CINreferralDate]

INSERT #ErrorCINLevel
SELECT '8640','CIN Reason for closure code invalid (see Reason for Closure table in CIN Census code set)',[CINDetails_ID], [CINreferralDate], [CINclosureDate]
FROM [#Stat_CIN_CINDetails] cin
WHERE [ReasonForClosure] NOT IN ('RC1','RC2','RC3','RC4','RC5','RC6','RC7','RC8')

INSERT #ErrorCINLevel
SELECT '8805','A CIN case cannot have a CIN closure date without a Reason for Closure',[CINDetails_ID], [CINreferralDate], [CINclosureDate]
FROM [#Stat_CIN_CINDetails] cin
WHERE [CINclosureDate] IS NOT NULL AND [ReasonForClosure] IS NULL 

INSERT #ErrorCINLevel
SELECT '8565','Activity shown after a case has been closed',[CINDetails_ID], [CINreferralDate], [CINclosureDate]
FROM [#Stat_CIN_CINDetails] cin
WHERE EXISTS (SELECT 1 FROM [#Stat_CIN_Assessments] asmt WHERE asmt.[CINDetails_ID] = cin.[CINDetails_ID] AND
([CINclosureDate] < [AssessmentActualStartDate] OR [CINclosureDate] < [AssessmentAuthorisationDate]))
OR EXISTS (SELECT 1 FROM [#Stat_CIN_Section47] s47 WHERE s47.[CINDetails_ID] = cin.[CINDetails_ID] AND
([CINclosureDate] < [DateOfInitialCPC] OR [CINclosureDate] < [S47ActualStartDate]))
OR [CINclosureDate] < cin.[DateOfInitialCPC]
OR EXISTS (SELECT 1 FROM [#Stat_CIN_Plans] cplan WHERE cplan.[CINDetails_ID] = cin.[CINDetails_ID] AND
([CINclosureDate] < [CINPlanStartDate] OR [CINclosureDate] < [CINPlanEndDate]))
OR EXISTS (SELECT 1 FROM [#Stat_CIN_ChildProtectionPlans] cpp WHERE cpp.[CINDetails_ID] = cin.[CINDetails_ID] AND
[CINclosureDate] < [CPPendDate])

INSERT #ErrorCINLevel
SELECT '8868','CIN episode is shown as closed, however Section 47 enquiry is not shown as completed by ICPC date or ICPC not required flag',[CINDetails_ID], [CINreferralDate], [CINclosureDate]
FROM [#Stat_CIN_CINDetails] cin
WHERE [CINclosureDate] IS NOT NULL AND EXISTS (
SELECT 1 FROM [#Stat_CIN_Section47] s47 WHERE s47.[CINDetails_ID] = cin.[CINDetails_ID] AND
[DateOfInitialCPC] IS NULL AND ([ICPCnotRequired] IS NULL OR [ICPCnotRequired] = 0))

INSERT #ErrorCINLevel
SELECT '8867','CIN episode is shown as closed, however Assessment is not shown as completed',[CINDetails_ID], [CINreferralDate], [CINclosureDate]
FROM [#Stat_CIN_CINDetails] cin
WHERE [CINclosureDate] IS NOT NULL AND EXISTS (
SELECT 1 FROM [#Stat_CIN_Assessments] asmt WHERE asmt.[CINDetails_ID] = cin.[CINDetails_ID] AND
[AssessmentAuthorisationDate] IS NULL)

INSERT #ErrorCINLevel
SELECT '8810','A CIN case cannot have a Reason for Closure without a CIN Closure Date',[CINDetails_ID], [CINreferralDate], [CINclosureDate]
FROM [#Stat_CIN_CINDetails] cin
WHERE [CINclosureDate] IS NULL AND [ReasonForClosure] IS NOT NULL

INSERT #ErrorCINLevel
SELECT '8825Q','Reason for Closure code RC8 (case closed after assessment) has been returned but there is no assessment present for the episode.',[CINDetails_ID], [CINreferralDate], [CINclosureDate]
FROM [#Stat_CIN_CINDetails] cin
WHERE [ReasonForClosure] = 'RC8' AND NOT EXISTS (SELECT 1 FROM [#Stat_CIN_Assessments] asmt WHERE asmt.[CINDetails_ID] = cin.[CINDetails_ID])

INSERT #ErrorCINLevel
SELECT '8585Q','Please check: CIN episode shows Died as the Closure Reason, however child has no recorded Date of Death',[CINDetails_ID], [CINreferralDate], [CINclosureDate]
FROM [#Stat_CIN_CINDetails] cin INNER JOIN [#Stat_CIN_Child] ch ON ch.[Child_XML_ID] = cin.[Child_XML_ID]
WHERE [ReasonForClosure] = 'RC2' AND ch.[PersonDeathDate] IS NULL

INSERT #ErrorCINLevel
SELECT '2990','Activity is recorded against a case marked as ''Case closed after assessment, no further action''',[CINDetails_ID], [CINreferralDate], [CINclosureDate]
FROM [#Stat_CIN_CINDetails] cin
WHERE [ReasonForClosure] = 'RC8' AND (EXISTS (SELECT 1 FROM [#Stat_CIN_Section47] s47 WHERE s47.[CINDetails_ID] = cin.[CINDetails_ID])
OR EXISTS (SELECT 1 FROM [#Stat_CIN_Plans] cplan WHERE cplan.[CINDetails_ID] = cin.[CINDetails_ID])
OR EXISTS (SELECT 1 FROM [#Stat_CIN_ChildProtectionPlans] cpp WHERE cpp.[CINDetails_ID] = cin.[CINDetails_ID])
OR [DateOfInitialCPC] IS NOT NULL)

INSERT #ErrorCINLevel
SELECT '8568','RNFA flag is missing or invalid',[CINDetails_ID], [CINreferralDate], [CINclosureDate]
FROM [#Stat_CIN_CINDetails] cin INNER JOIN [#Stat_CIN_Child] ch ON ch.[Child_XML_ID] = cin.[Child_XML_ID]
WHERE [ReferralNFA] IS NULL OR [ReferralNFA] NOT IN (0,1)

INSERT #ErrorChildLevel
select '8815','More than one open CIN Details episode (a module with no CIN Closure Date) has been provided for this child and case is not a referral with no further action.',[LAchildID],[UPN],[PersonBirthDate],[GenderCurrent],ch.[Child_XML_ID]
from [#Stat_CIN_Child] ch
INNER JOIN (SELECT [Child_XML_ID] FROM [#Stat_CIN_CINDetails] WHERE [CINclosureDate] IS NULL
AND ([ReferralNFA] = 0 OR [ReferralNFA] IS NULL)
GROUP BY [Child_XML_ID]
HAVING COUNT(*) > 1) cin_count ON ch.[Child_XML_ID] = cin_count.[Child_XML_ID]

INSERT #ErrorChildLevel
select '8816','An open CIN episode is shown and case is not a referral with no further action, but it is not the latest episode.',[LAchildID],[UPN],[PersonBirthDate],[GenderCurrent],ch.[Child_XML_ID]
from [#Stat_CIN_Child] ch
WHERE EXISTS (SELECT 1 FROM [#Stat_CIN_CINDetails] cin_a
INNER JOIN [#Stat_CIN_CINDetails] cin_b ON cin_a.[Child_XML_ID] = cin_b.[Child_XML_ID]
WHERE ch.[Child_XML_ID] = cin_a.[Child_XML_ID]
AND cin_a.[CINclosureDate] IS NULL
AND cin_a.[ReferralNFA] = 0 
AND cin_b.[CINreferralDate] > cin_a.[CINreferralDate]
) 

INSERT #ErrorChildLevel
select '8820','The dates on the CIN episodes for this child overlap',[LAchildID],[UPN],[PersonBirthDate],[GenderCurrent],ch.[Child_XML_ID]
from [#Stat_CIN_Child] ch
WHERE EXISTS (SELECT 1 FROM [#Stat_CIN_CINDetails] cin_a
INNER JOIN [#Stat_CIN_CINDetails] cin_b ON cin_a.[Child_XML_ID] = cin_b.[Child_XML_ID]
WHERE ch.[Child_XML_ID] = cin_a.[Child_XML_ID] AND cin_a.[CINDetails_ID] <> cin_b.[CINDetails_ID]
AND cin_a.[CINreferralDate] >= cin_b.[CINreferralDate]
AND cin_a.[CINreferralDate] < ISNULL(cin_b.[CINclosureDate], CASE WHEN cin_b.[ReferralNFA] = 0 THEN @CensusEndDate END)
)

INSERT #ErrorCINLevel
SELECT '8831','Activity is recorded against a case marked as a referral with no further action',[CINDetails_ID], [CINreferralDate], [CINclosureDate]
FROM [#Stat_CIN_CINDetails] cin
WHERE [ReferralNFA] = 1 
AND (EXISTS (SELECT 1 FROM [#Stat_CIN_Assessments] asmt WHERE asmt.[CINDetails_ID] = cin.[CINDetails_ID] AND
([AssessmentActualStartDate] IS NOT NULL OR [AssessmentAuthorisationDate] IS NOT NULL))
OR EXISTS (SELECT 1 FROM [#Stat_CIN_Section47] s47 WHERE s47.[CINDetails_ID] = cin.[CINDetails_ID] AND
([DateOfInitialCPC] IS NOT NULL OR [S47ActualStartDate] IS NOT NULL))
OR cin.[DateOfInitialCPC] IS NOT NULL 
)

INSERT #ErrorCINLevel
SELECT '8839','Within one CINDetails group there are 2 or more open S47 Assessments',cin.[CINDetails_ID], [CINreferralDate], [CINclosureDate]
FROM [#Stat_CIN_CINDetails] cin
INNER JOIN (SELECT [CINDetails_ID] FROM [#Stat_CIN_Section47]
WHERE [DateOfInitialCPC] IS NULL AND ([ICPCnotRequired] IS NULL OR ICPCnotRequired = 0)
GROUP BY [CINDetails_ID]
HAVING COUNT(*) > 1
)s47 ON s47.[CINDetails_ID] = cin.[CINDetails_ID]

INSERT #ErrorCINLevel
SELECT '8890','A Section 47 enquiry is shown as starting when there is another Section 47 Enquiry ongoing',cin.[CINDetails_ID], [CINreferralDate], [CINclosureDate]
FROM [#Stat_CIN_CINDetails] cin
WHERE EXISTS (SELECT 1 FROM [#Stat_CIN_Section47] s47_a
INNER JOIN [#Stat_CIN_Section47] s47_b ON s47_a.[CINDetails_ID] = s47_b.[CINDetails_ID]
WHERE cin.[CINDetails_ID] = s47_a.[CINDetails_ID] AND s47_a.[Section47_ID] <> s47_b.[Section47_ID]
AND s47_a.[S47ActualStartDate] >= s47_b.[S47ActualStartDate]
AND s47_a.[S47ActualStartDate] < ISNULL(s47_b.[DateOfInitialCPC], CASE WHEN s47_b.[ICPCnotRequired] = 0 THEN @CensusEndDate END)
)

INSERT #ErrorCINLevel
SELECT '8896','Within one CINDetails group there are 2 or more open Assessments groups',cin.[CINDetails_ID], [CINreferralDate], [CINclosureDate]
FROM [#Stat_CIN_CINDetails] cin
INNER JOIN (SELECT [CINDetails_ID] FROM [#Stat_CIN_Assessments]
WHERE [AssessmentAuthorisationDate] IS NULL
GROUP BY [CINDetails_ID]
HAVING COUNT(*) > 1
) asmt ON asmt.[CINDetails_ID] = cin.[CINDetails_ID]

INSERT #ErrorAssessmentLevel
SELECT '1103','The assessment start date cannot be before the referral date',asmt.[Assessments_ID],asmt.[AssessmentActualStartDate],asmt.[CINdetails_ID]
FROM  [#Stat_CIN_Assessments] asmt INNER JOIN [#Stat_CIN_CINDetails] cin ON asmt.[CINdetails_ID] = cin.[CINdetails_ID]
WHERE [AssessmentActualStartDate] < [CINReferralDate]

INSERT #ErrorAssessmentLevel
SELECT '8608','Assessment Start Date cannot be later than its End Date',asmt.[Assessments_ID],asmt.[AssessmentActualStartDate],asmt.[CINdetails_ID]
FROM  [#Stat_CIN_Assessments] asmt
WHERE [AssessmentActualStartDate] > [AssessmentAuthorisationDate]

SET DATEFIRST 1
DECLARE @AsessmentOverdueThreshold date = DATEADD(DAY, -63, @CensusEndDate) -- 45 working days + 18 weekend days = 63 calendar days
SET @AsessmentOverdueThreshold = CASE WHEN DATEPART(WEEKDAY,@AsessmentOverdueThreshold) in (6,7) -- Move it back more if it's Saturday or Sunday
     THEN DATEADD(DAY, 5 - DATEPART(WEEKDAY,@AsessmentOverdueThreshold),@AsessmentOverdueThreshold)
	 ELSE @AsessmentOverdueThreshold END
	 
INSERT #ErrorAssessmentLevel
SELECT '8670Q','Please check: Assessment started more than 45 working days before the end of the census year.  However, there is no Assessment end date.',asmt.[Assessments_ID],asmt.[AssessmentActualStartDate],asmt.[CINdetails_ID]
FROM [#Stat_CIN_Assessments] asmt 
WHERE [AssessmentAuthorisationDate] IS NULL 
AND [AssessmentActualStartDate] < @AsessmentOverdueThreshold

INSERT #ErrorAssessmentLevel
SELECT '8897','Parental or child factors at assessment information is missing from a completed assessment',asmt.[Assessments_ID],asmt.[AssessmentActualStartDate],asmt.[CINdetails_ID]
FROM [#Stat_CIN_Assessments] asmt 
WHERE [AssessmentAuthorisationDate] >= @CensusStartDate
AND NOT EXISTS (SELECT 1 from [#Stat_CIN_AssessmentFactors] af
WHERE asmt.[Assessments_ID] = af.[Assessments_ID] AND
[AssessmentFactors] In ('1A','1B','1C','2A','2B','2C','3A','3B','3C','4A','4B','4C','5A','5B','5C','6A',
'6B','6C','7A','8B','8C','8D','8E','8F','9A','10A','11A','12A','13A','14A','15A','16A','17A','18B','18C',
'19B','19C','20','21','22A','23A','24A'))

INSERT #ErrorAssessmentLevel
SELECT '8614','Parental or child factors at assessment should only be present for a completed assessment.',asmt.[Assessments_ID],asmt.[AssessmentActualStartDate],asmt.[CINdetails_ID]
FROM [#Stat_CIN_Assessments] asmt 
WHERE [AssessmentAuthorisationDate] IS NULL
AND EXISTS (SELECT 1 from [#Stat_CIN_AssessmentFactors] af
WHERE asmt.[Assessments_ID] = af.[Assessments_ID])

INSERT #ErrorAssessmentLevel
SELECT '8696','Assessment end date must fall within the census year',asmt.[Assessments_ID],asmt.[AssessmentActualStartDate],asmt.[CINdetails_ID]
FROM [#Stat_CIN_Assessments] asmt 
WHERE [AssessmentAuthorisationDate] < @CensusStartDate OR [AssessmentAuthorisationDate] > @CensusEndDate

INSERT #ErrorAssessmentLevel
SELECT '8736','For an Assessment that has not been completed, the start date must fall within the census year',asmt.[Assessments_ID],asmt.[AssessmentActualStartDate],asmt.[CINdetails_ID]
FROM [#Stat_CIN_Assessments] asmt 
WHERE [AssessmentAuthorisationDate] IS NULL AND ([AssessmentActualStartDate] < @CensusStartDate OR AssessmentActualStartDate > @CensusEndDate)

INSERT #ErrorAssessmentLevel
SELECT '8898','The assessment has more than one parental or child factors with the same code',asmt.[Assessments_ID],asmt.[AssessmentActualStartDate],asmt.[CINdetails_ID]
FROM [#Stat_CIN_Assessments] asmt INNER JOIN
(SELECT [Assessments_ID] FROM [#Stat_CIN_AssessmentFactors] 
GROUP BY [Assessments_ID]
HAVING COUNT(DISTINCT [AssessmentFactors]) < COUNT([AssessmentFactors])
) af ON af.[Assessments_ID] = asmt.[Assessments_ID]

INSERT #ErrorAssessmentLevel
 --The following code detects one case in Bristol's data that COLLECT does not flag, unclear if the rule has been misinterpreted
SELECT '8899Q','Please check: A child identified as having a disability does not have a disability factor recorded at the end of assessment.',asmt.[Assessments_ID],asmt.[AssessmentActualStartDate],asmt.[CINdetails_ID]
FROM [#Stat_CIN_Assessments] asmt 
INNER JOIN [#Stat_CIN_CINDetails] cin ON cin.CINdetails_ID = asmt.CINdetails_ID
INNER JOIN [#Stat_CIN_Child] ch ON cin.Child_XML_ID = ch.Child_XML_ID
WHERE asmt.[AssessmentAuthorisationDate] >= @CensusStartDate
AND EXISTS (SELECT 1 from [#Stat_CIN_Disability] d where d.ChildCharacteristics_ID = ch.ChildCharacteristics_ID
and d.[Disability]<>'NONE')
AND NOT EXISTS (SELECT 1 FROM #Stat_CIN_AssessmentFactors af 
WHERE asmt.Assessments_ID = af.Assessments_ID AND af.[AssessmentFactors] in ('5A','6A'))

INSERT #ErrorCINLevel
SELECT '8863','An Assessment is shown as starting when there is another Assessment ongoing',cin.[CINDetails_ID], [CINreferralDate], [CINclosureDate]
FROM [#Stat_CIN_CINDetails] cin
WHERE EXISTS (SELECT 1 FROM [#Stat_CIN_Assessments] asmt_a
INNER JOIN [#Stat_CIN_Assessments] asmt_b ON asmt_a.[CINDetails_ID] = asmt_b.[CINDetails_ID]
WHERE cin.[CINDetails_ID] = asmt_a.[CINDetails_ID] AND asmt_a.[Assessments_ID] <> asmt_b.[Assessments_ID]
AND asmt_a.[AssessmentActualStartDate] >= asmt_b.[AssessmentActualStartDate]
AND asmt_a.[AssessmentActualStartDate] < ISNULL(asmt_b.[AssessmentAuthorisationDate],@CensusEndDate)
)

INSERT #ErrorAssessmentLevel
SELECT '8869','The assessment factors code "21" cannot be used in conjunction with any other assessment factors.',asmt.[Assessments_ID],asmt.[AssessmentActualStartDate],asmt.[CINdetails_ID]
FROM [#Stat_CIN_Assessments] asmt INNER JOIN
(SELECT [Assessments_ID] FROM [#Stat_CIN_AssessmentFactors] 
GROUP BY [Assessments_ID]
HAVING COUNT(CASE WHEN [AssessmentFactors] = '21' THEN 1 END) > 0
AND COUNT(CASE WHEN [AssessmentFactors] <> '21' THEN 1 END) > 0
) af ON af.[Assessments_ID] = asmt.[Assessments_ID]

INSERT #ErrorCINLevel
SELECT '8873','When there is only one assessment on the episode and the factors code "21 No factors identified" has been used for the completed assessment, the reason for closure ''RC8'' must be used.',cin.[CINDetails_ID], [CINreferralDate], [CINclosureDate]
FROM [#Stat_CIN_CINDetails] cin
INNER JOIN (SELECT [CINDetails_ID], COUNT(CASE WHEN af.[AssessmentFactors]='21' then 1 end) F21Count FROM [#Stat_CIN_Assessments] asmt
LEFT JOIN [#Stat_CIN_AssessmentFactors] af ON asmt.Assessments_ID = af.Assessments_ID
GROUP BY [CINDetails_ID]
HAVING COUNT(*) = 1
) f21 ON cin.[CINDetails_ID] = f21.[CINDetails_ID]
AND cin.ReasonForClosure <> 'RC8'
AND f21.F21Count > 0
 

INSERT #ErrorAssessmentLevel
SELECT '8617','Code 8A has been returned. This code is not a valid code.',asmt.[Assessments_ID],asmt.[AssessmentActualStartDate],asmt.[CINdetails_ID]
FROM [#Stat_CIN_Assessments] asmt INNER JOIN
(SELECT [Assessments_ID] FROM [#Stat_CIN_AssessmentFactors] WHERE [AssessmentFactors] = '8A' 
GROUP BY [Assessments_ID]
) af ON af.[Assessments_ID] = asmt.[Assessments_ID]

INSERT #ErrorCINLevel
SELECT '4000','CIN Plan details provided for a referral with no further action',[CINDetails_ID], [CINreferralDate], [CINclosureDate]
FROM [#Stat_CIN_CINDetails] cin
WHERE ReferralNFA = 1 AND EXISTS (SELECT 1 FROM [#Stat_CIN_Plans] cplan
WHERE cin.[CINDetails_ID] = cplan.[CINDetails_ID]
)

INSERT #ErrorCINLevel
SELECT '4001','A CIN Plan cannot run concurrently with a Child Protection Plan',[CINDetails_ID], [CINreferralDate], [CINclosureDate]
FROM [#Stat_CIN_CINDetails] cin
WHERE EXISTS (SELECT 1 FROM [#Stat_CIN_Plans] cplan
   WHERE cin.[CINDetails_ID] = cplan.[CINDetails_ID] and cplan.CINPlanEndDate IS NULL
) AND EXISTS (SELECT 1 FROM [#Stat_CIN_ChildProtectionPlans] cpp
   WHERE cin.[CINDetails_ID] = cpp.[CINDetails_ID] and cpp.CPPEndDate IS NULL
)

INSERT #ErrorCINLevel
SELECT '4003','A CPP review date is shown as being held at the same time as an open CIN Plan',[CINDetails_ID], [CINreferralDate], [CINclosureDate]
FROM [#Stat_CIN_CINDetails] cin
WHERE EXISTS (SELECT 1 FROM [#Stat_CIN_Plans] cplan
INNER JOIN [#Stat_CIN_ChildProtectionPlans] cpp ON cplan.[CINDetails_ID] = cpp.[CINDetails_ID]
INNER JOIN [#Stat_CIN_Reviews] rev ON rev.[ChildProtectionPlans_ID] = cpp.[ChildProtectionPlans_ID]
WHERE cin.[CINDetails_ID] = cplan.[CINDetails_ID] 
AND CPPreviewDate > [CINPlanStartdate] --Guidance seems to suggest a review ON the CINPlanStartDate should flag an error, but common in practice in Bristol's data and not flagged in practice on COLLECT
AND CPPreviewDate < [CINPlanEndDate]
)

INSERT #ErrorCINLevel
SELECT '4004','This child is showing more than one open CIN Plan, i.e. with no End Date',cin.[CINDetails_ID], [CINreferralDate], [CINclosureDate]
FROM [#Stat_CIN_CINDetails] cin
INNER JOIN (SELECT [CINDetails_ID] FROM [#Stat_CIN_Plans] WHERE [CINPlanEndDate] IS NULL
GROUP BY [CINDetails_ID]
HAVING COUNT(*) > 1
) cplans ON cplans.[CINDetails_ID] = cin.[CINDetails_ID]

INSERT #ErrorCINPlanLevel
SELECT '4008','CIN Plan shown as starting after the child’s Date of Death',[CINPlan_ID], [CINPlanStartDate], cplan.[CINDetails_ID]
FROM [#Stat_CIN_Plans] cplan 
INNER JOIN [#Stat_CIN_CINDetails] cin ON cin.[CINDetails_ID] = cplan.[CINDetails_ID]
INNER JOIN [#Stat_CIN_Child] ch ON ch.[Child_XML_ID] = cin.[Child_XML_ID]
WHERE cplan.[CINPlanStartDate] > ch.[PersonDeathDate]

INSERT #ErrorCINPlanLevel
SELECT '4009','CIN Plan cannot end after the child’s Date of Death',[CINPlan_ID], [CINPlanStartDate], cplan.[CINDetails_ID]
FROM [#Stat_CIN_Plans] cplan 
INNER JOIN [#Stat_CIN_CINDetails] cin ON cin.[CINDetails_ID] = cplan.[CINDetails_ID]
INNER JOIN [#Stat_CIN_Child] ch ON ch.[Child_XML_ID] = cin.[Child_XML_ID]
WHERE ch.[PersonDeathDate] IS NOT NULL AND (cplan.[CINPlanEndDate] IS NULL OR cplan.[CINPlanEndDate] > ch.[PersonDeathDate])

INSERT #ErrorCINPlanLevel
SELECT '4010','CIN Plan start date is missing or out of data collection period',[CINPlan_ID], [CINPlanStartDate], cplan.[CINDetails_ID]
FROM [#Stat_CIN_Plans] cplan
WHERE cplan.CINPlanStartDate IS NULL OR cplan.CINPlanStartDate > @CensusEndDate

INSERT #ErrorCINPlanLevel
SELECT '4011','CIN Plan End Date earlier than Start Date',[CINPlan_ID], [CINPlanStartDate], cplan.[CINDetails_ID]
FROM [#Stat_CIN_Plans] cplan
WHERE cplan.[CINPlanEndDate] < cplan.[CINPlanStartDate]

INSERT #ErrorCINPlanLevel
SELECT '4012Q','CIN Plan shown as starting and ending on the same day – please check',[CINPlan_ID], [CINPlanStartDate], cplan.[CINDetails_ID]
FROM [#Stat_CIN_Plans] cplan
WHERE cplan.[CINPlanEndDate] = cplan.[CINPlanStartDate]

INSERT #ErrorCINPlanLevel
SELECT '4013','CIN Plan end date must fall within the census year',[CINPlan_ID], [CINPlanStartDate], cplan.[CINDetails_ID]
FROM [#Stat_CIN_Plans] cplan
WHERE cplan.[CINPlanEndDate] > @CensusEndDate OR cplan.[CINPlanEndDate] < @CensusStartDate

INSERT #ErrorCINLevel
SELECT '4014','CIN Plan data contains overlapping dates',[CINDetails_ID], [CINreferralDate], [CINclosureDate]
FROM [#Stat_CIN_CINDetails] cin 
WHERE EXISTS (SELECT 1 FROM [#Stat_CIN_Plans] cplan_a
INNER JOIN [#Stat_CIN_Plans] cplan_b ON cplan_a.[CINDetails_ID] = cplan_b.[CINDetails_ID]
WHERE cin.[CINDetails_ID] = cplan_a.[CINDetails_ID] AND cplan_a.[CINPlan_ID] <> cplan_b.[CINPlan_ID]
AND cplan_a.[CINPlanStartDate] >= cplan_b.[CINPlanStartDate]
AND cplan_a.[CINPlanStartDate] <= ISNULL(cplan_b.[CINPlanEndDate],@CensusEndDate)
AND cplan_a.[CINPlanStartDate] <> cplan_b.[CINPlanEndDate]
)

INSERT #ErrorCINPlanLevel
SELECT '4015','The CIN Plan start date cannot be before the referral date',[CINPlan_ID], [CINPlanStartDate], cplan.[CINDetails_ID]
FROM [#Stat_CIN_Plans] cplan 
INNER JOIN [#Stat_CIN_CINDetails] cin ON cin.[CINDetails_ID] = cplan.[CINDetails_ID]
WHERE cplan.[CINPlanStartDate] < cin.CINReferralDate

INSERT #ErrorCINLevel
SELECT '4016','A CIN Plan has been reported as open at the same time as a Child Protection Plan.',[CINDetails_ID], [CINreferralDate], [CINclosureDate]
FROM [#Stat_CIN_CINDetails] cin 
WHERE EXISTS (SELECT 1 FROM [#Stat_CIN_Plans] cplan
INNER JOIN [#Stat_CIN_ChildProtectionPlans] cpp ON cplan.[CINDetails_ID] = cpp.[CINDetails_ID]
WHERE cin.[CINDetails_ID] = cplan.[CINDetails_ID]
AND cplan.[CINPlanStartDate] >= cpp.[CPPstartDate]
AND cplan.[CINPlanStartDate] <= ISNULL(cpp.[CPPendDate],@CensusEndDate)
AND cplan.[CINPlanStartDate] <> cpp.[CPPendDate]
)

INSERT #ErrorCINLevel
SELECT '4017','A CIN Plan has been reported as open at the same time as a Child Protection Plan.',[CINDetails_ID], [CINreferralDate], [CINclosureDate]
FROM [#Stat_CIN_CINDetails] cin 
WHERE EXISTS (SELECT 1 FROM [#Stat_CIN_Plans] cplan
INNER JOIN [#Stat_CIN_ChildProtectionPlans] cpp ON cplan.[CINDetails_ID] = cpp.[CINDetails_ID]
WHERE cin.[CINDetails_ID] = cplan.[CINDetails_ID]
AND cpp.[CPPstartDate] >= cplan.[CINPlanStartDate]
AND cpp.[CPPstartDate] <= ISNULL(cplan.[CINPlanEndDate],@CensusEndDate)
AND cpp.[CPPstartDate] <> cplan.[CINPlanEndDate]
)

INSERT #ErrorSection47Level
SELECT '1104','The date of the initial child protection conference cannot be before the referral date',[Section47_ID], [S47ActualStartDate], s47.[CINDetails_ID]
FROM [#Stat_CIN_Section47] s47
INNER JOIN [#Stat_CIN_CINDetails] cin ON cin.[CINDetails_ID] = s47.[CINDetails_ID]
WHERE s47.[DateOfInitialCPC] < [CINReferralDate]

INSERT #ErrorSection47Level
SELECT '8615','Section 47 Enquiry Start Date must be present and cannot be later than the date of the initial Child Protection Conference',[Section47_ID], [S47ActualStartDate], s47.[CINDetails_ID]
FROM [#Stat_CIN_Section47] s47
WHERE s47.[DateOfInitialCPC] IS NOT NULL 
AND (s47.[S47ActualStartDate] IS NULL OR s47.[S47ActualStartDate] > s47.[DateOfInitialCPC])

INSERT #ErrorSection47Level
SELECT '2889','The S47 start date cannot be before the referral date.',[Section47_ID], [S47ActualStartDate], s47.[CINDetails_ID]
FROM [#Stat_CIN_Section47] s47
INNER JOIN [#Stat_CIN_CINDetails] cin ON cin.[CINDetails_ID] = s47.[CINDetails_ID]
WHERE s47.[S47ActualStartDate] < [CINReferralDate]

INSERT #ErrorCINLevel
SELECT '2884','An initial child protection conference is recorded at both the S47 and CIN Details level and it should only be recorded in one',[CINDetails_ID], [CINreferralDate], [CINclosureDate]
FROM [#Stat_CIN_CINDetails] cin 
WHERE EXISTS (SELECT 1 FROM [#Stat_CIN_Section47] s47
WHERE cin.[CINDetails_ID] = s47.[CINDetails_ID]
AND cin.[DateOfInitialCPC] = s47.[DateOfInitialCPC]
)

INSERT #ErrorSection47Level
SELECT '8740','For a Section 47 Enquiry that has not held the Initial Child Protection Conference by the end of the census year, the start date must fall within the census year',[Section47_ID], [S47ActualStartDate], s47.[CINDetails_ID]
FROM [#Stat_CIN_Section47] s47
WHERE s47.DateOfInitialCPC IS NULL
AND [ICPCnotRequired] = 0
AND (S47ActualStartDate < @CensusStartDate OR S47ActualStartDate > @CensusEndDate)

SET DATEFIRST 1
DECLARE @S47OverdueThreshold date = DATEADD(DAY, -21, @CensusEndDate) -- 15 working days + 6 weekend days = 21 calendar days
SET @S47OverdueThreshold = CASE WHEN DATEPART(WEEKDAY,@S47OverdueThreshold) in (6,7) -- Move it back more if it's Saturday or Sunday
     THEN DATEADD(DAY, 5 - DATEPART(WEEKDAY,@S47OverdueThreshold),@S47OverdueThreshold)
	 ELSE @S47OverdueThreshold END
	 
INSERT #ErrorSection47Level
SELECT '8675Q','Please check: S47 Enquiry started more than 15 working days before the end of the census year. However, there is no date of Initial Child Protection Conference.',[Section47_ID], [S47ActualStartDate], s47.[CINDetails_ID]
FROM [#Stat_CIN_Section47] s47
WHERE s47.DateOfInitialCPC IS NULL
AND [ICPCnotRequired] = 0
AND (S47ActualStartDate < @S47OverdueThreshold)

SET DATEFIRST 1
INSERT #ErrorSection47Level
SELECT '8870Q','Please check: The Target Date for Initial Child Protection Conference should not be a weekend',[Section47_ID], [S47ActualStartDate], s47.[CINDetails_ID]
FROM [#Stat_CIN_Section47] s47
WHERE DATEPART(WEEKDAY, s47.[InitialCPCtarget]) in (6,7)

INSERT #ErrorSection47Level
SELECT '8715','Date of Initial Child Protection Conference must fall within the census year',[Section47_ID], [S47ActualStartDate], s47.[CINDetails_ID]
FROM [#Stat_CIN_Section47] s47
WHERE [DateOfInitialCPC] < @CensusStartDate OR [DateOfInitialCPC] > @CensusEndDate

SET DATEFIRST 1
INSERT #ErrorSection47Level
SELECT '8875','The Date of Initial Child Protection Conference cannot be a weekend',[Section47_ID], [S47ActualStartDate], s47.[CINDetails_ID]
FROM [#Stat_CIN_Section47] s47
WHERE DATEPART(WEEKDAY, s47.[DateOfInitialCPC]) in (6,7)

INSERT #ErrorCINLevel
SELECT '2991Q','Please check: A Section 47 module is recorded and there is no assessment on the episode',[CINDetails_ID], [CINreferralDate], [CINclosureDate]
FROM [#Stat_CIN_CINDetails] cin 
WHERE EXISTS (SELECT 1 FROM [#Stat_CIN_Section47] s47
WHERE cin.[CINDetails_ID] = s47.[CINDetails_ID])
AND NOT EXISTS (SELECT 1 FROM [#Stat_CIN_Assessments] asmt
WHERE asmt.[CINDetails_ID] = asmt.[CINDetails_ID])

INSERT #ErrorCINLevel
SELECT '8832','Child Protection details provided for a referral with no further action',[CINDetails_ID], [CINreferralDate], [CINclosureDate]
FROM [#Stat_CIN_CINDetails] cin 
WHERE cin.ReferralNFA = 1 
AND EXISTS (SELECT 1 FROM [#Stat_CIN_ChildProtectionPlans] cpp
WHERE cin.[CINDetails_ID] = cpp.[CINDetails_ID]
)

INSERT #ErrorCINLevel
SELECT '8935','This child is showing more than one open Child Protection plan, i.e. with no End Date',cin.[CINDetails_ID], [CINreferralDate], [CINclosureDate]
FROM [#Stat_CIN_CINDetails] cin 
INNER JOIN (SELECT [CINDetails_ID] FROM [#Stat_CIN_ChildProtectionPlans] WHERE [CPPendDate] IS NULL
GROUP BY [CINDetails_ID]
HAVING COUNT(*) > 1
) cpp ON cpp.[CINDetails_ID] = cin.[CINDetails_ID]

INSERT #ErrorCPPLevel
SELECT '8905','Initial Category of Abuse code missing or invalid (see Category of Abuse table in CIN Census code set)',[ChildProtectionPlans_ID],[CPPstartDate],cpp.[CINdetails_ID] 
FROM [#Stat_CIN_ChildProtectionPlans] cpp 
WHERE [InitialCategoryOfAbuse] IS NULL OR [InitialCategoryOfAbuse] NOT IN ('NEG','PHY','SAB','EMO','MUL')

INSERT #ErrorCPPLevel
SELECT '8910','Latest Category of Abuse code missing or invalid (see Category of Abuse table in CIN Census code set)',[ChildProtectionPlans_ID],[CPPstartDate],cpp.[CINdetails_ID] 
FROM [#Stat_CIN_ChildProtectionPlans] cpp 
WHERE [LatestCategoryOfAbuse] IS NULL OR [LatestCategoryOfAbuse] NOT IN ('NEG','PHY','SAB','EMO','MUL')

INSERT #ErrorCPPLevel
SELECT '8720','Child Protection Plan Start Date missing or out of data collection period',[ChildProtectionPlans_ID],[CPPstartDate],cpp.[CINdetails_ID] 
FROM [#Stat_CIN_ChildProtectionPlans] cpp 
WHERE [CPPstartDate] IS NULL OR [CPPstartDate] > @CensusEndDate

INSERT #ErrorCPPLevel
SELECT '8915','Child Protection Plan shown as starting after the child’s Date of Death',[ChildProtectionPlans_ID],[CPPstartDate],cpp.[CINdetails_ID] 
FROM [#Stat_CIN_ChildProtectionPlans] cpp 
INNER JOIN [#Stat_CIN_CINDetails] cin ON cin.[CINDetails_ID] = cpp.[CINDetails_ID]
INNER JOIN [#Stat_CIN_Child] ch ON ch.[Child_XML_ID] = cin.[Child_XML_ID]
WHERE cpp.[CPPstartDate] > ch.[PersonDeathDate]

INSERT #ErrorCPPLevel
SELECT '8920','Child Protection Plan cannot end after the child’s Date of Death',[ChildProtectionPlans_ID],[CPPstartDate],cpp.[CINdetails_ID] 
FROM [#Stat_CIN_ChildProtectionPlans] cpp 
INNER JOIN [#Stat_CIN_CINDetails] cin ON cin.[CINDetails_ID] = cpp.[CINDetails_ID]
INNER JOIN [#Stat_CIN_Child] ch ON ch.[Child_XML_ID] = cin.[Child_XML_ID]
WHERE ch.[PersonDeathDate] IS NOT NULL AND (cpp.[CPPendDate] IS NULL OR cpp.[CPPendDate] > ch.[PersonDeathDate])

INSERT #ErrorCPPLevel
SELECT '8925','Child Protection Plan End Date earlier than Start Date',[ChildProtectionPlans_ID],[CPPstartDate],cpp.[CINdetails_ID] 
FROM [#Stat_CIN_ChildProtectionPlans] cpp 
WHERE [CPPendDate] < [CPPstartDate]

INSERT #ErrorCPPLevel
SELECT '8930','Child Protection Plan End Date must fall within the census year',[ChildProtectionPlans_ID],[CPPstartDate],cpp.[CINdetails_ID] 
FROM [#Stat_CIN_ChildProtectionPlans] cpp 
WHERE [CPPendDate] < @CensusStartDate OR [CPPendDate] > @CensusEndDate

INSERT #ErrorCPPLevel
SELECT '8840','Child Protection Plan cannot start and end on the same day',[ChildProtectionPlans_ID],[CPPstartDate],cpp.[CINdetails_ID] 
FROM [#Stat_CIN_ChildProtectionPlans] cpp 
WHERE [CPPendDate] = [CPPstartDate]

INSERT #ErrorCPPLevel
SELECT '8841','The review date cannot be on the same day or before the Child protection Plan start date.',[ChildProtectionPlans_ID],[CPPstartDate],cpp.[CINdetails_ID] 
FROM [#Stat_CIN_ChildProtectionPlans] cpp 
WHERE EXISTS (SELECT 1 FROM [#Stat_CIN_Reviews] rev
   WHERE rev.[ChildProtectionPlans_ID] = cpp.[ChildProtectionPlans_ID]
   AND rev.CPPreviewDate <= cpp.CPPstartDate)

--8842Q omitted as it conflicts with the current load process, which doesn't capture the Reviews tag in its own right

INSERT #ErrorCINLevel
SELECT '8940','Child Protection Plan data contains overlapping dates',[CINDetails_ID], [CINreferralDate], [CINclosureDate]
FROM [#Stat_CIN_CINDetails] cin 
WHERE EXISTS (SELECT 1 FROM [#Stat_CIN_ChildProtectionPlans] cpp_a
INNER JOIN [#Stat_CIN_ChildProtectionPlans] cpp_b ON cpp_a.[CINDetails_ID] = cpp_b.[CINDetails_ID]
WHERE cin.[CINDetails_ID] = cpp_a.[CINDetails_ID] AND cpp_a.[ChildProtectionPlans_ID] <> cpp_b.[ChildProtectionPlans_ID]
AND cpp_a.[CPPstartDate] >= cpp_b.[CPPstartDate]
AND cpp_a.[CPPstartDate] <= ISNULL(cpp_b.[CPPendDate],@CensusEndDate)
)

INSERT #ErrorCPPLevel
SELECT '2885','Child protection plan shown as starting a different day to the initial child protection conference',[ChildProtectionPlans_ID],[CPPstartDate],cpp.[CINdetails_ID] 
FROM [#Stat_CIN_ChildProtectionPlans] cpp 
INNER JOIN [#Stat_CIN_CINDetails] cin ON cin.[CINDetails_ID] = cpp.[CINDetails_ID]
WHERE cpp.[CPPstartDate] BETWEEN @CensusStartDate AND @CensusEndDate
AND (cin.[DateOfInitialCPC] <> cpp.[CPPStartDate] OR cin.[DateOfInitialCPC] IS NULL)
AND NOT EXISTS (SELECT 1 FROM [#Stat_CIN_Section47] s47
WHERE s47.[CINDetails_ID] = cin.[CINDetails_ID]
AND s47.[DateOfInitialCPC] = cpp.[CPPStartDate])

INSERT #ErrorCPPLevel
SELECT '1105','The child protection plan start date cannot be before the referral date',[ChildProtectionPlans_ID],[CPPstartDate],cpp.[CINdetails_ID] 
FROM [#Stat_CIN_ChildProtectionPlans] cpp 
INNER JOIN [#Stat_CIN_CINDetails] cin ON cin.[CINDetails_ID] = cpp.[CINDetails_ID]
WHERE cpp.[CPPStartDate] < cin.[CINReferralDate]

--review the errors
SELECT * FROM #ErrorReturnLevel
SELECT * FROM #ErrorChildLevel

SELECT [LAchildID],[UPN],[PersonBirthDate],e.* FROM #ErrorCINLevel e
INNER JOIN [#Stat_CIN_CINDetails] cin ON e.[CINDetails_ID] = cin.[CINDetails_ID]
INNER JOIN [#Stat_CIN_Child] ch ON ch.[Child_XML_ID] = cin.[Child_XML_ID]
ORDER BY 4

SELECT [LAchildID],[UPN],[PersonBirthDate],e.* FROM #ErrorAssessmentLevel e
INNER JOIN [#Stat_CIN_CINDetails] cin ON e.[CINDetails_ID] = cin.[CINDetails_ID]
INNER JOIN [#Stat_CIN_Child] ch ON ch.[Child_XML_ID] = cin.[Child_XML_ID]
ORDER BY 4

SELECT [LAchildID],[UPN],[PersonBirthDate],e.* FROM #ErrorCINPlanLevel e
INNER JOIN [#Stat_CIN_CINDetails] cin ON e.[CINDetails_ID] = cin.[CINDetails_ID]
INNER JOIN [#Stat_CIN_Child] ch ON ch.[Child_XML_ID] = cin.[Child_XML_ID]
ORDER BY 4

SELECT [LAchildID],[UPN],[PersonBirthDate],e.* FROM #ErrorSection47Level e
INNER JOIN [#Stat_CIN_CINDetails] cin ON e.[CINDetails_ID] = cin.[CINDetails_ID]
INNER JOIN [#Stat_CIN_Child] ch ON ch.[Child_XML_ID] = cin.[Child_XML_ID]
ORDER BY 4

SELECT [LAchildID],[UPN],[PersonBirthDate],e.* FROM #ErrorCPPLevel e
INNER JOIN [#Stat_CIN_CINDetails] cin ON e.[CINDetails_ID] = cin.[CINDetails_ID]
INNER JOIN [#Stat_CIN_Child] ch ON ch.[Child_XML_ID] = cin.[Child_XML_ID]
ORDER BY 4

--tidy up the error 
DROP TABLE #ErrorReturnLevel;DROP TABLE #ErrorChildLevel;DROP TABLE #ErrorCINLevel
DROP TABLE #ErrorAssessmentLevel;DROP TABLE #ErrorCINPlanLevel;DROP TABLE #ErrorSection47Level
DROP TABLE #ErrorCPPLevel

*/
/************************* Section 2: ERROR CHECKING end *************************/


/************************* Section 3: EXPORT start *************************/
/*
--use variables to build up the header
DECLARE @Header XML;
DECLARE @CollectionDetails XML;
DECLARE @Source XML;
DECLARE @Content XML;

--create each section of the header. The inner elements inherit their names from the column names in the table
--the outer element is explicitly named in the XML PATH statement
SET @CollectionDetails = (SELECT Collection, Year, ReferenceDate FROM [#Stat_CIN_Header] FOR XML PATH('CollectionDetails'),TYPE)
SET @Source = (SELECT SourceLevel, LEA, SoftwareCode, Release, SerialNo
                     ,CONVERT(varchar, [DateTime], 126)+'.0Z' AS [DateTime] --format this EXACTLY AS in the original file
                 FROM [#Stat_CIN_Header] FOR XML PATH('Source'),TYPE)
SET @Content = (SELECT CBDSLevel FROM [#Stat_CIN_Header]
				WHERE [Year] < 2022 --change in schema FOR 2022
				FOR XML PATH('CBDSLevels'),ROOT('Content'),TYPE)
--wrap the three header sections in the header tag
SET @Header =(SELECT @CollectionDetails, @Source, @Content FOR XML PATH('Header'),TYPE)

DECLARE @Children XML;
--as children is a repeating element, we need to SELECT the fields using a query

SET @children = (
--the outermost SELECT statement is selecting from each row in the [#Stat_CIN_Child] table
--the ChildIdentifiers element simply selects fields from that table
--the other elements run subqueries to select related elements from the detail tables
--ChildCharacteristics selects elements from the [#Stat_CIN_Child] AS well
SELECT
--ChildIdentifiers element contents are defined below
 (SELECT child.LAchildID
        ,child.UPN
        ,child.FormerUPN
        ,child.UPNunknown
        ,child.PersonBirthDate  
        ,child.ExpectedPersonBirthDate --note that this should only be populated when the previous field is absent
                                       --but this is not enforced by the export query, it should be corrected in the data
                                       --during the data cleansing phase
        ,child.GenderCurrent
        ,child.PersonDeathDate
        FOR XML PATH('ChildIdentifiers'),TYPE
        )
--ChildCharacteristics element here 
 ,(SELECT child.Ethnicity --name of column becomes name of element
        ,(SELECT dis.Disability 
            FROM [#Stat_CIN_Disability] dis 
           WHERE dis.ChildCharacteristics_ID = child.ChildCharacteristics_ID --this is a subquery "join" between the disability and child tables
             FOR XML PATH (''),TYPE) AS Disabilities --this element is named explicitly
        FOR XML PATH('ChildCharacteristics'),TYPE
        )
--CINdetails element starts here 
 ,(SELECT --begin with fields taken from [Stat_CIN_CINdetails] directly, mostly getting their names from fields
          CIND.CINreferralDate
         ,ISNULL(CIND.[ReferralSource],'') AS [ReferralSource]
         ,CIND.[PrimaryNeedCode]
         ,CIND.[CINclosureDate]
         ,CIND.[ReasonForClosure]
         ,CIND.[DateOfInitialCPC]
         --assessments require another subquery
         ,(SELECT asmt.AssessmentActualStartDate
                 ,asmt.AssessmentInternalReviewDate
                 ,asmt.AssessmentAuthorisationDate
                 ,ISNULL( --we want the option to force the FactorsIdentifiedAtAssessment to appear even if there are no related factors in the following subquery
                 --factors require ANOTHER subquery
                 (SELECT afactor.AssessmentFactors
                     FROM [#Stat_CIN_AssessmentFactors] afactor
                    WHERE afactor.Assessments_ID = asmt.Assessments_ID --this is a subquery "join" between the assessment and factor tables
                    ORDER BY afactor.AssessmentFactors
                    FOR XML PATH (''),TYPE)
                    ,CASE WHEN asmt.AssessmentAuthorisationDate IS NOT NULL THEN '' END)  --only force FactorsIdentifiedAtAssessment to appear for authorised assessments
                    AS FactorsIdentifiedAtAssessment --name of the wrapper element
             FROM [#Stat_CIN_Assessments] asmt
            WHERE asmt.CINdetails_ID = CIND.CINdetails_ID --this is a subquery "join" between the assessment and CIN tables
            ORDER BY asmt.Assessments_ID--get the assessments to come out in the order the appear in the input
            FOR XML PATH ('Assessments'),TYPE) --name of the wrapper element
         --CIN Plans requires another subquery
         ,(SELECT cplan.[CINPlanStartDate]
                 ,cplan.[CINPlanEndDate]
             FROM [#Stat_CIN_Plans] cplan
            WHERE cplan.CINdetails_ID = CIND.CINdetails_ID  --this is a subquery "join" between the s47 and CIN tables
            FOR XML PATH ('CINPlanDates'),TYPE) --name of the wrapper element
         --Section47 requires another subquery
         ,(SELECT s47.S47ActualStartDate
                 ,s47.InitialCPCtarget
                 ,s47.DateOfInitialCPC
                 ,CASE WHEN s47.ICPCnotRequired = 1 THEN 'true' 
                       WHEN s47.ICPCnotRequired = 0 THEN 'false' END AS ICPCnotRequired --need to explicitly name this element because of the case statement
             FROM [#Stat_CIN_Section47] s47
            WHERE s47.CINdetails_ID = CIND.CINdetails_ID  --this is a subquery "join" between the s47 and CIN tables
            FOR XML PATH ('Section47'),TYPE) --name of the wrapper element
         --back to getting data FROM the CIND table level
         ,CASE WHEN CIND.[ReferralNFA] = 1 THEN 'true' 
               WHEN CIND.[ReferralNFA] = 0 THEN 'false' END AS [ReferralNFA] --need to explicitly name this element because of the case statement
         --ChildProtectionPlans is also a subquery
         ,(SELECT CPplans.[CPPstartDate]
                 ,CPplans.[CPPendDate]
                 ,CPplans.[InitialCategoryOfAbuse]
                 ,CPplans.[LatestCategoryOfAbuse]
                 ,CPplans.[NumberOfPreviousCPP]
                 --reviews require ANOTHER subquery
                 ,(SELECT rev.CPPreviewDate
                     FROM [#Stat_CIN_Reviews] rev
                    WHERE rev.ChildProtectionPlans_ID = CPplans.ChildProtectionPlans_ID  --this is a subquery "join" between the cp plan and review tables
                    ORDER BY rev.Review_ID --output the reviews in the order they appeared in the input
                    FOR XML PATH (''),TYPE) AS Reviews --name of the wrapper element 
             FROM [#Stat_CIN_ChildProtectionPlans] CPplans
            WHERE CPplans.CINdetails_ID = CIND.CINdetails_ID
            ORDER BY CPplans.ChildProtectionPlans_ID--output the CP plans in the order they appeared in the input
            FOR XML PATH ('ChildProtectionPlans'),TYPE) --name of the wrapper element
     FROM [#Stat_CIN_CINdetails] CIND
    WHERE CIND.Child_XML_ID = child.Child_XML_ID
    ORDER BY CIND.CINdetails_ID --output the CIN episodes in the order they appeared in the input
        FOR XML PATH('CINdetails'),TYPE
        )
  FROM [#Stat_CIN_Child] child
  ORDER BY child.Child_XML_ID --output the children in the order they appeared in the input
  FOR XML PATH('Child'),ROOT('Children'),TYPE
  )

--print the header for the sake of the SQLCMD export to file
SELECT '<?xml version="1.0" encoding="UTF-8"?>' 
--combine the header and children into a single message
SELECT @Header,@Children FOR XML PATH('Message'),type

*/
/************************* Section 3: EXPORT end *************************/

--finally, tidy up all the temp tables
DROP TABLE [#Stat_CIN_Header];DROP TABLE [#Stat_CIN_Disability];DROP TABLE [#Stat_CIN_AssessmentFactors]
DROP TABLE [#Stat_CIN_Assessments];DROP TABLE [#Stat_CIN_Plans];DROP TABLE [#Stat_CIN_Section47]
DROP TABLE [#Stat_CIN_Reviews];DROP TABLE [#Stat_CIN_ChildProtectionPlans];DROP TABLE [#Stat_CIN_CINdetails] 
DROP TABLE [#Stat_CIN_Child]
