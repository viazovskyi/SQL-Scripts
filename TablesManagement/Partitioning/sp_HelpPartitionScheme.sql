USE [master]
GO
IF NOT EXISTS (SELECT 1 FROM sys.all_objects WHERE object_id = OBJECT_ID('[dbo].[sp_HelpPartitionScheme]') AND TYPE = 'P')
	EXECUTE ('CREATE PROCEDURE [dbo].[sp_HelpPartitionScheme] AS BEGIN PRINT ''Container for [dbo].[sp_HelpPartitionScheme] (C) Pavel Pawlowski'' END')
GO
/* *******************************************************
sp_HelpPartitionScheme v 0.51 (2017-10-30)

Feedback: mailto:pavel.pawlowski@hotmail.cz

MIT License

Copyright (c) 2017 Pavel Pawlowski

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

Description: 
    Provides information about the partition scheme including the partition function it is based on and partition boundary values
    Procedure also lists depended tables and indexes using the partition scheme


Parameters:
     @psName            nvarchar(128)   = NULL  --Name of the partition scheme
    ,@listDependencies  bit             = 1     --Specifies whether list dependencies of the partition scheme

Result table schema:
CREATE TABLE #Results(
     [PartitionSchemeName]   sysname         NOT NULL   --Partition scheme name
    ,[PartitionFunctionName] sysname         NOT NULL   --Associated partition function name
    ,[PartitionFunctionID]   int             NOT NULL   --Associated partition function ID
    ,[ParameterDataType]     sysname         NOT NULL   --PF parameter data type
    ,[BoundaryType]          nvarchar(5)     NOT NULL   --Partition function boundary type
    ,[PartitionID]           int             NOT NULL   --ID of the partition defined by partition function
    ,[DestinationFileGroup]  sysname         NOT NULL   --Destination file group of the partition
    ,[LeftBoundaryIncluded]  char(1)         NULL       --Specifies whether left boundary value is included in the partition
    ,[RightBoundaryIncluded] char(1)         NULL       --Specifies whether right boundary value is included in the partition
    ,[LeftBoundary]          sql_variant     NULL       --Left boundary value
    ,[RightBoundary]         sql_variant     NULL       --Right boundary value
    ,[PartitionRange]        nvarchar(4000)  NULL       --Partition range in human readable form [NEXT_USED] for next file group used during partition function split
);
*/
ALTER PROCEDURE [dbo].[sp_HelpPartitionScheme]
     @psName            nvarchar(128)   = NULL  --Name of the partition scheme
    ,@listDependencies  bit             = 0     --Specifies whether list dependencies of the partition scheme
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE
        @caption            nvarchar(max)	    --Procedure caption
        ,@msg               nvarchar(max)		--message
        ,@psID              int                 --ID of partition Function
        ,@partitionsCount   int                 --count of boundary values

	SET @caption = N'sp_HelpPartitionScheme v 0.51 (2017-10-30) (C) 2014 - 2017 Pavel Pawlowski' + NCHAR(13) + NCHAR(10) + 
				   N'==========================================================================';
	RAISERROR(@caption, 0, 0) WITH NOWAIT;

	--if partition function name is not provided, print Help
	IF @psName IS NULL
	BEGIN
    	RAISERROR(N'', 0, 0) WITH NOWAIT;
    	RAISERROR(N'Provides detailed information about the partition scheme including partitions and their boundary values defined by related partition function..', 0, 0) WITH NOWAIT;
        RAISERROR(N'Provides information about depended objects like tables/indexed views/indexes utilizing the partition scheme', 0, 0) WITH NOWAIT;
		RAISERROR(N'', 0, 0);
		RAISERROR(N'Usage:', 0, 0);
		RAISERROR(N'[sp_HelpPartitionScheme] {@psName = ''partition_scheme_name''} [,@listDependencies]', 0, 0);
		RAISERROR(N'', 0, 0);
		SET @msg = N'Parameters:
     @psName            nvarchar(128)   = NULL - name of the partition scheme for which the information should be returned
    ,@listDependencies  bit             = 1    - Specifies whether list dependencies of the partition scheme';
		RAISERROR(@msg, 0, 0);

	SET @msg = N'
Table schema to hold results for partition scheme information
-------------------------------------------------------------
CREATE TABLE #Results(
     [PartitionSchemeName]   sysname         NOT NULL   --Partition scheme name
    ,[PartitionFunctionName] sysname         NOT NULL   --Associated partition function name
    ,[PartitionFunctionID]   int             NOT NULL   --Associated partition function ID
    ,[ParameterDataType]     sysname         NOT NULL   --PF parameter data type
    ,[BoundaryType]          nvarchar(5)     NOT NULL   --Partition function boundary type
    ,[PartitionID]           int             NOT NULL   --ID of the partition defined by partition function
    ,[DestinationFileGroup]  sysname         NOT NULL   --Destination file group of the partition
    ,[LeftBoundaryIncluded]  char(1)         NULL       --Specifies whether left boundary value is included in the partition
    ,[RightBoundaryIncluded] char(1)         NULL       --Specifies whether right boundary value is included in the partition
    ,[LeftBoundary]          sql_variant     NULL       --Left boundary value
    ,[RightBoundary]         sql_variant     NULL       --Right boundary value
    ,[PartitionRange]        nvarchar(4000)  NULL       --Partition range in human readable form [NEXT_USED] for next file group used during partition function split
);';
		RAISERROR(@msg, 0, 0);

		RETURN
	END

    --Get the partition function ID and count of partitions it will generate
    SELECT
         @psID              = ps.data_space_id
    FROM sys.partition_schemes ps
    WHERE ps.[name] = @psName

    IF @psID IS NULL
    BEGIN
        RAISERROR(N'Partition scheme [%s] does not exists', 15, 0, @psName) WITH NOWAIT;
        RETURN;
    END;

    RAISERROR(N'Retrieving information for partition scheme [%s]', 0, 0, @psName) WITH NOWAIT;
    --Get partition information
    WITH PartitionBaseData AS (  --Get partition data
        SELECT
             ps.[name]                                      AS PartitionSchemeName                                    
            ,pf.[name]                                      AS PartitionFunctionName
            ,pf.function_id                                 AS PartitionFunctionID
            ,CASE WHEN boundary_value_on_right = 0 THEN N'LEFT' ELSE 'RIGHT' END AS BoundaryType
            ,dds.destination_id                             AS PartitionID
            ,prv.[value]                                    AS LeftBoundary
            ,LEAD(prv.[value]) OVER(ORDER BY dds.destination_id) AS RightBoundary
            ,ISNULL (
		        CASE ppt.[name] --Format the value for displaying
			        WHEN N'date' THEN LEFT(CONVERT(varchar(30), CONVERT(date, prv.[value] ), 120), 10)
			        WHEN N'datetime' THEN CONVERT(varchar(30), CONVERT(datetime, prv.[value] ), 121)
			        WHEN N'datetime2' THEN CONVERT(varchar(30), CONVERT(datetime2, prv.[value] ), 121)
			        ELSE CONVERT(varchar(30), prv.[value] )
		        END
                , N''
            )                                               AS LeftBoundaryStr
		    ,ISNULL (
                CASE ppt.[name] --Format the value for displaying
			        WHEN N'date' THEN CONVERT(varchar(30), LEFT(CONVERT(date, LEAD(prv.[value]) OVER(ORDER BY dds.destination_id)), 121), 10)
			        WHEN N'datetime' THEN CONVERT(varchar(30), CONVERT(datetime, LEAD(prv.[value]) OVER(ORDER BY dds.destination_id)), 121)
			        WHEN N'datetime2' THEN CONVERT(varchar(30), CONVERT(datetime2, LEAD(prv.[value]) OVER(ORDER BY dds.destination_id)), 121)
			        ELSE CONVERT(varchar(30), LEAD(prv.[value]) OVER(ORDER BY dds.destination_id))
                END
                , N''
            )                                               AS RightBoundaryStr            
            ,ppt.[name]                                     AS ParameterDataType
            ,fg.[name]                                      AS FileGroupName
        FROM sys.partition_schemes ps   --information about partition scheme
        INNER JOIN sys.partition_functions pf ON pf.function_id = ps.function_id    --information about partition function
        INNER JOIN sys.partition_parameters pp ON pp.function_id = pf.function_id AND pp.parameter_id = 1   --information about partition function parameter
        INNER JOIN sys.types ppt ON ppt.system_type_id = pp.system_type_id  --information about the parameter data type
        INNER JOIN sys.destination_data_spaces dds ON dds.partition_scheme_id = ps.data_space_id --get destination data spaces to get partitions and destination file groups
		INNER JOIN sys.filegroups fg on dds.data_space_id = fg.data_space_id	--FileGroups to get file group name for the destination data space
        LEFT JOIN sys.partition_range_values prv ON prv.function_id = pf.function_id AND prv.boundary_id = dds.destination_id - 1 AND prv.parameter_id = 1
        WHERE
            ps.data_space_id = @psID
    )
    SELECT
         pbd.PartitionSchemeName                                    AS PartitionSchemeName
        ,pbd.PartitionFunctionName                                  AS PartitionFunctionName
        ,pbd.PartitionFunctionID                                    AS PartitionFunctionID
        ,pbd.ParameterDataType                                      AS ParameterDataType
        ,pbd.BoundaryType                                           AS BoundaryType
        ,pbd.PartitionID                                            AS PartitionID
        ,pbd.FileGroupName                                          AS DestinationFileGroup
		,CASE 
			WHEN LeftBoundary IS NULL THEN NULL
			WHEN BoundaryType = 'RIGHT' THEN 'Y'
			ELSE 'N'
		END                                                         AS LeftBoundaryIncluded
		,CASE 
			WHEN RightBoundary IS NULL THEN NULL
			WHEN BoundaryType = 'RIGHT' THEN N'N'
			ELSE N'Y'
		END                                                         AS RightBoundaryIncluded
        ,pbd.LeftBoundary                                           AS LeftBoundary
        ,pbd.RightBoundary                                          AS RightBoundary

        ,CASE 
            WHEN pbd.LeftBoundary IS NULL AND pbd.RightBoundary IS NULL THEN '[NEXT_USED]'
            ELSE
                RIGHT(REPLICATE(' ', MAX(LEN(LeftBoundaryStr)) OVER())
                    + LeftBoundaryStr, LEN(MAX(LEN(LeftBoundaryStr)) OVER())
                 )
                +
		        CASE 
			        WHEN LeftBoundary IS NULL THEN N'    '
			        WHEN BoundaryType = 'RIGHT' THEN N' <= '
			        ELSE N' <  '
		        END 
                + N' [x] '
		        +
		        CASE 
			        WHEN RightBoundary IS NULL THEN N'    '
			        WHEN BoundaryType = 'RIGHT' THEN N' <  '
			        ELSE N' <= '
		        END 
		        +
		        ISNULL(RightBoundaryStr, N'')
        END                                                         AS PartitionRange
    FROM PartitionBaseData pbd
    ORDER BY pbd.PartitionID

    IF @listDependencies = 1
    BEGIN
        RAISERROR(N'Retrieving information about depended objects (Tables and/or Indexed Views)', 0, 0) WITH NOWAIT;
        --list depended partitioned tables and partitioned views
        SELECT
            ps.name                     AS PartitionSchemeName
            ,SCHEMA_NAME(o.schema_id)   AS SchemaName
	        ,o.[name]                   AS ObjectName
            ,o.object_id                AS ObjectID
            ,o.[type]                   AS ObjectType
            ,o.[type_desc]              AS ObjectTypeName
            ,o.create_date              AS Created
            ,o.modify_date              AS Modified
            ,i.[type_desc]              AS StorageType
        INTO #PT
        FROM sys.objects o
        INNER JOIN sys.indexes i ON i.object_id = o.object_id AND i.index_id <= 1
        INNER JOIN sys.data_spaces ds on ds.data_space_id = i.data_space_id
        INNER JOIN sys.partition_schemes ps ON ds.data_space_id = ps.data_space_id
        WHERE ps.data_space_id = @psID

        IF EXISTS(SELECT 1 FROM #PT)
            SELECT * FROM #PT ORDER BY SchemaName, ObjectName

        RAISERROR(N'Retrieving information about depended non clustered indexes', 0, 0) WITH NOWAIT;
        --list all non clustered indexes
        SELECT
             ps.[name]                  AS PartitionSchemeName
            ,SCHEMA_NAME(o.schema_id)   AS SchemaName
	        ,o.[name]                   AS ObjectName
            ,i.[name]                   AS IndexName
            ,o.object_id                AS ObjectID
            ,i.index_id                 AS IndexID
            ,i.[type]                   AS IndexType
            ,i.[type_desc]              AS IndexTypeName
            ,o.[type]                   AS ObjectType
            ,o.[type_desc]              AS ObjectTypeName
            ,ps.data_space_id           AS PartitionScheme_data_space_id
        INTO #PI
        FROM sys.objects o
        INNER JOIN sys.indexes i ON i.object_id = o.object_id AND i.index_id > 1
        INNER JOIN sys.data_spaces ds on ds.data_space_id = i.data_space_id
        INNER JOIN sys.partition_schemes ps ON ds.data_space_id = ps.data_space_id
        WHERE ps.data_space_id = @psID

        IF EXISTS(SELECT 1 FROM #PI)
            SELECT * FROM #PI ORDER BY SchemaName, ObjectName, IndexName

        DROP TABLE #PT;
        DROP TABLE #PI;
    END
    RAISERROR(N'', 0, 0) WITH NOWAIT;
END
GO
EXECUTE sp_ms_marksystemobject 'dbo.sp_HelpPartitionScheme'
GO
