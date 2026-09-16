{% macro get_count(q) %}
{% set r=run_query(q) %}{% if execute %}{{ return(r.columns[0].values()[0]) }}{% endif %}
{% endmacro %}

{% macro insert_result(run_id,pipeline_name,model_filter,src,tgt,ctype,status,details,sql) %}
{% set q %}
INSERT INTO PRACTICE.DQ_RESULTS
VALUES ('{{run_id}}','{{pipeline_name}}','{{model_filter}}','{{src}}','{{tgt}}','{{ctype}}','{{status}}','{{details}}','{{sql|replace("'","''")}}',CURRENT_TIMESTAMP)
{% endset %}
{% do run_query(q) %}
{% endmacro %}

{% macro structure_check(run_id,pipeline_name,model_filter,src,tgt,table_name) %}
{% set s=src.split('.') %}{% set t=tgt.split('.') %}{% set s_db=s[0] %}{% set s_sch=s[1] %}{% set s_tbl=s[-1] %}{% set t_db=t[0] %}{% set t_sch=t[1] %}{% set t_tbl=t[-1] %}
{% set cfg=run_query("SELECT TGT_TABLE,EXCLUDED_COLUMNS_SRC,EXCLUDED_COLUMNS_TGT FROM "~ref('DQ_TABLE_CONFIG')~" WHERE MODEL_FILTER='"~model_filter~"'") %}
{% set ex_s=[] %}{% set ex_t=[] %}
{% for row in cfg.rows %}
{% if row[0]==table_name %}
{% for c in fromjson(row[1] or '[]') %}{% do ex_s.append(c|upper) %}{% endfor %}
{% for c in fromjson(row[2] or '[]') %}{% do ex_t.append(c|upper) %}{% endfor %}
{% endif %}
{% endfor %}
{% set scq="SELECT COLUMN_NAME,DATA_TYPE FROM "~s_db~".INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME='"~s_tbl|upper~"' AND TABLE_SCHEMA='"~s_sch|upper~"'" %}
{% set tcq="SELECT COLUMN_NAME,DATA_TYPE FROM "~t_db~".INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME='"~t_tbl|upper~"' AND TABLE_SCHEMA='"~t_sch|upper~"'" %}
{% set scr=run_query(scq) %}{% set tcr=run_query(tcq) %}
{% set sc=[] %}{% for r in scr.rows %}{% if r[0]|upper not in ex_s %}{% do sc.append(r[0]~':'~r[1].split('(')[0]) %}{% endif %}{% endfor %}
{% set tc=[] %}{% for r in tcr.rows %}{% if r[0]|upper not in ex_t %}{% do tc.append(r[0]~':'~r[1].split('(')[0]) %}{% endif %}{% endfor %}
{% set st="PASS" if sc|sort==tc|sort else "FAIL" %}
{% do insert_result(run_id,pipeline_name,model_filter,src,tgt,"STRUCTURE_CHECK",st,"SRC="~sc|length~",TGT="~tc|length,scq~";"~tcq) %}
{% endmacro %}

{% macro count_check(run_id,pipeline_name,model_filter,src,tgt,src_filter,tgt_filter) %}
{% set qs="SELECT COUNT(*) FROM "~src~" WHERE "~src_filter %}{% set qt="SELECT COUNT(*) FROM "~tgt~" WHERE "~tgt_filter %}
{% set sc=get_count(qs|replace(';','')) %}{% set tc=get_count(qt|replace(';','')) %}
{% do insert_result(run_id,pipeline_name,model_filter,src,tgt,"COUNT_CHECK","PASS" if sc==tc else "FAIL","SRC="~sc~",TGT="~tc,qs~";"~qt) %}
{% endmacro %}

{% macro duplicate_check(run_id,pipeline_name,model_filter,src,tgt,keys,src_filter,tgt_filter) %}
{% set k=keys|join(',') %}
{% set qs="SELECT COUNT(*) FROM (SELECT "~k~",COUNT(*) FROM "~src~" WHERE "~src_filter~" GROUP BY "~k~" HAVING COUNT(*)>1) x" %}
{% set qt="SELECT COUNT(*) FROM (SELECT "~k~",COUNT(*) FROM "~tgt~" WHERE "~tgt_filter~" GROUP BY "~k~" HAVING COUNT(*)>1) y" %}
{% set sc=get_count(qs|replace(';','')) %}{% set tc=get_count(qt|replace(';','')) %}
{% do insert_result(run_id,pipeline_name,model_filter,src,tgt,"DUPLICATE_CHECK","PASS" if sc==0 and tc==0 else "FAIL","SRC_DUP="~sc~",TGT_DUP="~tc,qs~";"~qt) %}
{% endmacro %}

{% macro null_check(run_id,pipeline_name,model_filter,src,tgt,keys,src_filter,tgt_filter) %}
{% set cond=[] %}
{% for k in keys %}{% do cond.append(k~" IS NULL") %}{% endfor %}
{% set c=cond|join(' OR ') %}
{% set qs="SELECT COUNT(*) FROM "~src~" WHERE "~src_filter~" AND ("~c~")" %}{% set qt="SELECT COUNT(*) FROM "~tgt~" WHERE "~tgt_filter~" AND ("~c~")" %}
{% set sc=get_count(qs|replace(';','')) %}{% set tc=get_count(qt|replace(';','')) %}
{% do insert_result(run_id,pipeline_name,model_filter,src,tgt,"NULL_CHECK","PASS" if sc==0 and tc==0 else "FAIL","SRC_NULL="~sc~",TGT_NULL="~tc,qs~";"~qt) %}
{% endmacro %}

{% macro data_comparison(run_id,pipeline_name,model_filter,src,tgt,table_name,src_filter,tgt_filter) %}
{% set sdb=src.split('.')[0] %}{% set tdb=tgt.split('.')[0] %}
{% set cfg=run_query("SELECT EXCLUDED_COLUMNS_SRC,EXCLUDED_COLUMNS_TGT FROM "~ref('DQ_TABLE_CONFIG')~" WHERE MODEL_FILTER='"~model_filter~"' AND TGT_TABLE='"~table_name~"'") %}
{% set ex_s=fromjson(cfg.columns[0].values()[0] or '[]') %}{% set ex_t=fromjson(cfg.columns[1].values()[0] or '[]') %}
{% set sc=run_query("SELECT COLUMN_NAME FROM "~sdb~".INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME='"~src.split('.')[-1]|upper~"'").columns[0].values()|reject('in',ex_s or [])|list %}
{% set tc=run_query("SELECT COLUMN_NAME FROM "~tdb~".INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME='"~tgt.split('.')[-1]|upper~"'").columns[0].values()|reject('in',ex_t or [])|list %}
{% set cols=(sc|select('in',tc)|list)|join(',') %}{% if cols|trim=='' %}{% set cols='1' %}{% endif %}
{% set sql="SELECT COUNT(*) FROM (((SELECT "~cols~" FROM "~src~" WHERE "~src_filter~") MINUS (SELECT "~cols~" FROM "~tgt~" WHERE "~tgt_filter~")) UNION ((SELECT "~cols~" FROM "~tgt~" WHERE "~tgt_filter~") MINUS (SELECT "~cols~" FROM "~src~" WHERE "~src_filter~")))" %}
{% set d=get_count(sql|replace(';','')) %}
{% do insert_result(run_id,pipeline_name,model_filter,src,tgt,"DATA_COMPARISON","PASS" if d==0 else "FAIL","DIFF="~d,sql) %}
{% endmacro %}

{% macro business_rule_check(run_id,pipeline_name,model_filter) %}
{% set r=run_query("SELECT SOURCE_TABLE_NAME,TARGET_TABLE_NAME,RULE_NAME,RULE_SQL FROM "~ref('DQ_BUSINESS_RULES')~" WHERE MODEL_FILTER='"~model_filter~"' AND IS_ACTIVE='Y'") %}
{% for row in r.rows %}
{% set src_table=row[0] %}{% set tgt_table=row[1] %}{% set sql=row[3] %}{% set cnt=get_count(sql|replace(';','')) %}
{% do insert_result(run_id,pipeline_name,model_filter,src_table,tgt_table,"BUSINESS_RULE_"~row[2],"PASS" if cnt==0 else "FAIL","FAILED_RECORDS="~cnt,sql) %}
{% endfor %}
{% endmacro %}

{% macro run_dq_framework(model_filter,pipeline_name) %}
{% set run_id_query %}
SELECT 'RUN_'||TO_VARCHAR(CURRENT_DATE,'YYYYMMDD')||'_'||LPAD(COALESCE(MAX(TO_NUMBER(SPLIT_PART(RUN_ID,'_',3))),0)+1,4,'0')
FROM PRACTICE.DQ_RESULTS
WHERE RUN_ID LIKE 'RUN_'||TO_VARCHAR(CURRENT_DATE,'YYYYMMDD')||'_%'
{% endset %}
{% set run_id=run_query(run_id_query).columns[0].values()[0] %}
{% do log("DQ Execution ID: "~run_id,info=True) %}
{% set cfg=run_query("SELECT * FROM "~ref('DQ_TABLE_CONFIG')~" WHERE MODEL_FILTER='"~model_filter~"'") %}
{% for r in cfg.rows %}
{% set src=r[1] %}
{% set tgt=r[2] %}
{% set keys=fromjson(r[3]) %}
{% set src_filter=r[12] if r[12] and r[12]|trim!='' else '1=1' %}
{% set tgt_filter=r[13] if r[13] and r[13]|trim!='' else '1=1' %}
{% if r[6]=="Y" %}{% do count_check(run_id,pipeline_name,model_filter,src,tgt,src_filter,tgt_filter) %}{% endif %}
{% if r[7]=="Y" %}{% do duplicate_check(run_id,pipeline_name,model_filter,src,tgt,keys,src_filter,tgt_filter) %}{% endif %}
{% if r[8]=="Y" %}{% do null_check(run_id,pipeline_name,model_filter,src,tgt,keys,src_filter,tgt_filter) %}{% endif %}
{% if r[9]=="Y" %}{% do structure_check(run_id,pipeline_name,model_filter,src,tgt,tgt) %}{% endif %}
{% if r[10]=="Y" %}{% do data_comparison(run_id,pipeline_name,model_filter,src,tgt,tgt,src_filter,tgt_filter) %}{% endif %}
{% endfor %}
{% do business_rule_check(run_id,pipeline_name,model_filter) %}
{% endmacro %}