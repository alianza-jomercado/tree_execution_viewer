DECLARE
    CURSOR c_objs IS
        SELECT owner, object_name, object_type
        FROM dba_objects
        WHERE object_type = 'PACKAGE BODY'
        AND owner = 'VU_SFI'
        --AND object_name = 'SF_QPORTAL_WEB_TRANV2'
        ;

    v_subprogram VARCHAR2(128);
    
    -- Contadores para diagnóstico
    v_total_lines NUMBER := 0;
    v_processed_lines NUMBER := 0;
    v_subprograms_found NUMBER := 0;
    v_dependencies_found NUMBER := 0;
    v_internal_calls NUMBER := 0;
    v_external_calls NUMBER := 0;

    -- Colección optimizada basada en DBA_PROCEDURES
    TYPE t_subprogram_rec IS RECORD (
        procedure_name VARCHAR2(128),
        object_type VARCHAR2(19) -- PROCEDURE o FUNCTION
    );
    TYPE t_subprogram_tab IS TABLE OF t_subprogram_rec INDEX BY VARCHAR2(128);
    v_package_subprograms t_subprogram_tab := t_subprogram_tab();
    
    -- Índice para palabras reservadas (más eficiente que IN)
    TYPE t_reserved_words IS TABLE OF BOOLEAN INDEX BY VARCHAR2(50);
    v_reserved_words t_reserved_words := t_reserved_words();

        -- Cache para reducir llamadas repetidas a is_reserved_word
    TYPE t_word_cache IS TABLE OF BOOLEAN INDEX BY VARCHAR2(128);
    v_reserved_cache t_word_cache := t_word_cache();

    PROCEDURE init_reserved_words IS
    BEGIN
        -- Inicializar hash table de palabras reservadas para búsqueda O(1)
        v_reserved_words('SELECT') := TRUE;
        v_reserved_words('INSERT') := TRUE;
        v_reserved_words('UPDATE') := TRUE;
        v_reserved_words('DELETE') := TRUE;
        v_reserved_words('FROM') := TRUE;
        v_reserved_words('WHERE') := TRUE;
        v_reserved_words('AND') := TRUE;
        v_reserved_words('OR') := TRUE;
        v_reserved_words('NOT') := TRUE;
        v_reserved_words('NULL') := TRUE;
        v_reserved_words('TRUE') := TRUE;
        v_reserved_words('FALSE') := TRUE;
        v_reserved_words('BEGIN') := TRUE;
        v_reserved_words('END') := TRUE;
        v_reserved_words('IF') := TRUE;
        v_reserved_words('THEN') := TRUE;
        v_reserved_words('ELSE') := TRUE;
        v_reserved_words('LOOP') := TRUE;
        v_reserved_words('FOR') := TRUE;
        v_reserved_words('WHILE') := TRUE;
        v_reserved_words('CURSOR') := TRUE;
        v_reserved_words('OPEN') := TRUE;
        v_reserved_words('FETCH') := TRUE;
        v_reserved_words('CLOSE') := TRUE;
        v_reserved_words('COMMIT') := TRUE;
        v_reserved_words('ROLLBACK') := TRUE;
        v_reserved_words('EXCEPTION') := TRUE;
        v_reserved_words('WHEN') := TRUE;
        v_reserved_words('RAISE') := TRUE;
        v_reserved_words('RETURN') := TRUE;
        v_reserved_words('EXIT') := TRUE;
        v_reserved_words('GOTO') := TRUE;
        v_reserved_words('NUMBER') := TRUE;
        v_reserved_words('VARCHAR2') := TRUE;
        v_reserved_words('DATE') := TRUE;
        v_reserved_words('CHAR') := TRUE;
        v_reserved_words('BOOLEAN') := TRUE;
        v_reserved_words('PLS_INTEGER') := TRUE;
        v_reserved_words('TO_CHAR') := TRUE;
        v_reserved_words('TO_DATE') := TRUE;
        v_reserved_words('TO_NUMBER') := TRUE;
        v_reserved_words('NVL') := TRUE;
        v_reserved_words('NVL2') := TRUE;
        v_reserved_words('DECODE') := TRUE;
        v_reserved_words('COUNT') := TRUE;
        v_reserved_words('SUM') := TRUE;
        v_reserved_words('MAX') := TRUE;
        v_reserved_words('MIN') := TRUE;
        v_reserved_words('AVG') := TRUE;
        v_reserved_words('SYSDATE') := TRUE;
        v_reserved_words('USER') := TRUE;
        v_reserved_words('DUAL') := TRUE;
        v_reserved_words('ROWNUM') := TRUE;
        v_reserved_words('SUBSTR') := TRUE;
        v_reserved_words('LENGTH') := TRUE;
        v_reserved_words('UPPER') := TRUE;
        v_reserved_words('LOWER') := TRUE;
        v_reserved_words('TRIM') := TRUE;
        v_reserved_words('INSTR') := TRUE;
        v_reserved_words('REPLACE') := TRUE;
        v_reserved_words('VALUES') := TRUE;
        v_reserved_words('INTO') := TRUE;
        v_reserved_words('SET') := TRUE;
        v_reserved_words('BY') := TRUE;
        v_reserved_words('ASC') := TRUE;
        v_reserved_words('DESC') := TRUE;
        v_reserved_words('DISTINCT') := TRUE;
        v_reserved_words('UNIQUE') := TRUE;
        v_reserved_words('ALL') := TRUE;
        v_reserved_words('IS') := TRUE;
        v_reserved_words('AS') := TRUE;
        v_reserved_words('ON') := TRUE;
        v_reserved_words('INNER') := TRUE;
        v_reserved_words('OUTER') := TRUE;
        v_reserved_words('LEFT') := TRUE;
        v_reserved_words('RIGHT') := TRUE;
        v_reserved_words('FULL') := TRUE;
        v_reserved_words('JOIN') := TRUE;
        v_reserved_words('UNION') := TRUE;
        v_reserved_words('INTERSECT') := TRUE;
        v_reserved_words('MINUS') := TRUE;
        v_reserved_words('ORDER') := TRUE;
        v_reserved_words('GROUP') := TRUE;
        v_reserved_words('HAVING') := TRUE;
        v_reserved_words('CASE') := TRUE;
    END init_reserved_words;

    PROCEDURE add_row(
        p_owner VARCHAR2, 
        p_name VARCHAR2, 
        p_type VARCHAR2,
        p_subprogram VARCHAR2, 
        p_called_owner VARCHAR2, 
        p_called_object VARCHAR2,
        p_called_subprogram VARCHAR2, 
        p_called_type VARCHAR2, 
        p_dml VARCHAR2
    ) IS
    BEGIN
        -- Validación básica: solo evitar valores completamente vacíos
        IF p_called_object IS NULL OR LENGTH(TRIM(p_called_object)) = 0 THEN
            RETURN;
        END IF;
        
        -- Debug: mostrar valores antes de insertar
        /*
        IF p_called_object LIKE '%QDIGITO%' OR p_called_object LIKE '%QOBJECT%' THEN
            DBMS_OUTPUT.PUT_LINE('DEBUG ADD_ROW: ' || NVL(p_subprogram, 'NULL_SUBPROGRAM') || ' -> ' || 
                            'OWNER=[' || NVL(p_called_owner,'NULL') || '] ' ||
                            'OBJECT=[' || NVL(p_called_object,'NULL') || '] ' ||
                            'SUBPROGRAM=[' || NVL(p_called_subprogram,'NULL') || '] ' ||
                            'DML=[' || p_dml || ']');
        END IF;
        */
        BEGIN
            INSERT INTO OBJ_DEPENDENCIES_EXPORT
            VALUES (SUBSTR(NVL(p_owner,''), 1, 128), 
                SUBSTR(NVL(p_name,''), 1, 128), 
                SUBSTR(NVL(p_type,''), 1, 128), 
                SUBSTR(NVL(p_subprogram,''), 1, 128), 
                SUBSTR(NVL(p_called_owner,''), 1, 128), 
                SUBSTR(NVL(p_called_object,''), 1, 128), 
                SUBSTR(NVL(p_called_subprogram,''), 1, 128), 
                SUBSTR(NVL(p_called_type,''), 1, 128), 
                SUBSTR(NVL(p_dml,''), 1, 32));
            
            v_dependencies_found := v_dependencies_found + 1;
            
            -- Contar tipo de llamada
            IF p_dml = 'CALL' THEN
                IF p_called_owner IS NOT NULL AND p_called_owner = p_owner AND p_called_object = p_name THEN
                    v_internal_calls := v_internal_calls + 1;
                ELSE
                    v_external_calls := v_external_calls + 1;
                END IF;      
            END IF;          
        EXCEPTION
            WHEN DUP_VAL_ON_INDEX THEN
                NULL; -- Ignorar duplicados silenciosamente
            WHEN OTHERS THEN
                DBMS_OUTPUT.PUT_LINE('✗ ERROR INSERT: ' || SQLERRM);
                DBMS_OUTPUT.PUT_LINE('  Valores: OBJECT=[' || p_called_object || '] SUBPROGRAM=[' || p_called_subprogram || ']');
        END;
    END add_row;

    -- Función optimizada usando hash table
    FUNCTION is_package_subprogram(p_name VARCHAR2) RETURN BOOLEAN IS
        v_upper_name VARCHAR2(128) := UPPER(TRIM(p_name));
    BEGIN
        RETURN v_package_subprograms.EXISTS(v_upper_name);
    END is_package_subprogram;
    

    -- Función optimizada usando hash table
    FUNCTION is_reserved_word(p_name VARCHAR2) RETURN BOOLEAN IS
        v_upper_name VARCHAR2(50) := UPPER(TRIM(p_name));
        v_result BOOLEAN;
    BEGIN
        -- Check cache first to avoid repeated lookups
        IF v_reserved_cache.EXISTS(v_upper_name) THEN
            RETURN v_reserved_cache(v_upper_name);
        END IF;
        
        -- Lookup and cache result
        v_result := v_reserved_words.EXISTS(v_upper_name);
        v_reserved_cache(v_upper_name) := v_result;
        
        RETURN v_result;
    END is_reserved_word;
    
    -- Función para obtener el tipo de subprograma
    FUNCTION get_subprogram_type(p_name VARCHAR2) RETURN VARCHAR2 IS
        v_upper_name VARCHAR2(128) := UPPER(TRIM(p_name));
    BEGIN
        IF v_package_subprograms.EXISTS(v_upper_name) THEN
            RETURN v_package_subprograms(v_upper_name).object_type;
        END IF;
        RETURN 'PROCEDURE'; -- Default
    END get_subprogram_type;
    
    -- Procedimiento para debug/testing de regex - MEJORADO
    PROCEDURE test_regex_extraction(p_line VARCHAR2) IS
        v_upper_line VARCHAR2(4000) := UPPER(p_line);
        v_table VARCHAR2(128);
        v_package VARCHAR2(128);
        v_proc VARCHAR2(128);
        v_full_match VARCHAR2(200);
        v_pos NUMBER := 1;
        v_match_count NUMBER := 0;
    BEGIN
        DBMS_OUTPUT.PUT_LINE('=== TESTING REGEX ON: ' || p_line);
        
        -- Test INSERT
        IF REGEXP_LIKE(v_upper_line, 'INSERT\s+INTO\s+[A-Z_][A-Z0-9_]*') THEN
            v_table := REGEXP_SUBSTR(v_upper_line, 'INSERT\s+INTO\s+([A-Z_][A-Z0-9_]*)', 1, 1, NULL, 1);
            DBMS_OUTPUT.PUT_LINE('INSERT TABLE: [' || NVL(v_table, 'NULL') || ']');
        END IF;
        
        -- Test UPDATE
        IF REGEXP_LIKE(v_upper_line, 'UPDATE\s+[A-Z_][A-Z0-9_]*') THEN
            v_table := REGEXP_SUBSTR(v_upper_line, 'UPDATE\s+([A-Z_][A-Z0-9_]*)', 1, 1, NULL, 1);
            DBMS_OUTPUT.PUT_LINE('UPDATE TABLE: [' || NVL(v_table, 'NULL') || ']');
        END IF;
        
        -- Test package calls - MOSTRAR TODOS LOS MATCHES
        DBMS_OUTPUT.PUT_LINE('--- Buscando llamadas package.procedure ---');
        LOOP
            v_full_match := REGEXP_SUBSTR(v_upper_line, '\b[A-Z_][A-Z0-9_]*\.[A-Z_][A-Z0-9_]*\s*\(', v_pos);
            EXIT WHEN v_full_match IS NULL;
            
            v_match_count := v_match_count + 1;
            
            -- Extraer components usando método corregido
            v_package := REGEXP_SUBSTR(v_full_match, '^([A-Z_][A-Z0-9_]*)\.');
            v_package := RTRIM(v_package, '.');
            v_proc := REGEXP_SUBSTR(v_full_match, '\.([A-Z_][A-Z0-9_]*)\s*\(', 1, 1, NULL, 1);
            
            DBMS_OUTPUT.PUT_LINE('MATCH ' || v_match_count || ': [' || v_full_match || ']');
            DBMS_OUTPUT.PUT_LINE('  PACKAGE: [' || NVL(v_package, 'NULL') || ']');
            DBMS_OUTPUT.PUT_LINE('  PROC: [' || NVL(v_proc, 'NULL') || ']');
            
            -- Avanzar posición
            v_pos := REGEXP_INSTR(v_upper_line, '\b[A-Z_][A-Z0-9_]*\.[A-Z_][A-Z0-9_]*\s*\(', v_pos) + LENGTH(v_full_match);
            EXIT WHEN v_pos > LENGTH(v_upper_line);
        END LOOP;
        
        IF v_match_count = 0 THEN
            DBMS_OUTPUT.PUT_LINE('No se encontraron llamadas package.procedure');
        END IF;
        
        DBMS_OUTPUT.PUT_LINE('=== END TEST ===');
    END test_regex_extraction;
        
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== ANÁLISIS DE DEPENDENCIAS OPTIMIZADO CON DBA_PROCEDURES ===');
    
    -- Inicializar palabras reservadas
    init_reserved_words();
    
    -- Verificar que exista el objeto
    FOR obj IN c_objs LOOP
        --DBMS_OUTPUT.PUT_LINE('Analizando: ' || obj.owner || '.' || obj.object_name);
        
        -- PASO 1: CARGAR SUBPROGRAMAS USANDO DBA_PROCEDURES (OPTIMIZADO CON BULK COLLECT)
        --DBMS_OUTPUT.PUT_LINE('=== PASO 1: CARGANDO SUBPROGRAMAS DESDE DBA_PROCEDURES ===');
        
        DECLARE
            TYPE t_proc_tab IS TABLE OF dba_procedures%ROWTYPE;
            v_procs t_proc_tab;
        BEGIN
            -- Carga en bloque más eficiente usando BULK COLLECT
            SELECT * BULK COLLECT INTO v_procs
            FROM dba_procedures
            WHERE owner = obj.owner 
            AND object_name = obj.object_name
            AND procedure_name IS NOT NULL -- Excluir entrada del package principal
            ORDER BY procedure_name;
            
            -- Procesar los resultados en memoria
            FOR i IN 1..v_procs.COUNT LOOP
                IF v_procs(i).procedure_name IS NOT NULL THEN
                    v_package_subprograms(UPPER(v_procs(i).procedure_name)) := 
                        t_subprogram_rec(v_procs(i).procedure_name, v_procs(i).object_type);
                    --DBMS_OUTPUT.PUT_LINE('  Registrado: ' || v_procs(i).procedure_name || ' (' || v_procs(i).object_type || ')');

                END IF;
            END LOOP;
        END;
        
        --DBMS_OUTPUT.PUT_LINE('Total subprogramas cargados: ' || v_package_subprograms.COUNT);
        
        -- PASO 2: ANALIZAR DEPENDENCIAS CON CONOCIMIENTO PRECISO DE SUBPROGRAMAS
        --DBMS_OUTPUT.PUT_LINE('=== PASO 2: ANALIZANDO DEPENDENCIAS ===');
        
            -- Inicializar contadores
    v_subprogram := NULL;
    v_total_lines := 0;
    v_processed_lines := 0;
    v_subprograms_found := 0;
    v_dependencies_found := 0;
    v_internal_calls := 0;
    v_external_calls := 0;
    
    -- Precompilar patrones regex para mejor rendimiento
    DECLARE
        v_insert_pattern CONSTANT VARCHAR2(100) := 'INSERT\s+INTO\s+([A-Z_][A-Z0-9_]*)';
        v_update_pattern CONSTANT VARCHAR2(100) := 'UPDATE\s+([A-Z_][A-Z0-9_]*)';
        v_delete_pattern CONSTANT VARCHAR2(100) := 'DELETE\s+FROM\s+([A-Z_][A-Z0-9_]*)';
        v_select_pattern CONSTANT VARCHAR2(100) := 'FROM\s+([A-Z_][A-Z0-9_]*)';
        v_call_pattern CONSTANT VARCHAR2(100) := '([A-Z_][A-Z0-9_]*)\s*\(';
        v_ext_call_pattern CONSTANT VARCHAR2(100) := '\b[A-Z_][A-Z0-9_]*\.[A-Z_][A-Z0-9_]*\s*\(';
    BEGIN
        
        -- Procesar código fuente con BULK COLLECT para mejorar rendimiento
        DECLARE
            TYPE t_source_rec IS RECORD (
                line NUMBER,
                text VARCHAR2(4000)
            );
            TYPE t_source_tab IS TABLE OF t_source_rec;
            v_source_lines t_source_tab;
        BEGIN
            -- Cargar todo el código fuente de una vez
            SELECT line, text BULK COLLECT INTO v_source_lines
            FROM dba_source
            WHERE owner = obj.owner 
            AND name = obj.object_name 
            AND type = obj.object_type
            ORDER BY line;
            
        -- Procesar código en memoria para reducir context switching
        FOR i IN 1..v_source_lines.COUNT LOOP
            DECLARE
            src t_source_rec := v_source_lines(i);
            v_total_lines number;
                v_clean_line VARCHAR2(4000) := TRIM(src.text);
                v_upper_line VARCHAR2(4000);
            BEGIN
                -- Saltar líneas vacías y comentarios - OPTIMIZADO
                IF v_clean_line IS NULL OR v_clean_line LIKE '--%' THEN
                    CONTINUE;
                END IF;

                v_upper_line := UPPER(v_clean_line);
                v_processed_lines := v_processed_lines + 1;

                -- DEBUG: mostrar línea si contiene INS_GE_TAUXIL
                /*
                IF INSTR(v_upper_line, 'INS_GE_TAUXIL') > 0 THEN
                    DBMS_OUTPUT.PUT_LINE('DEBUG: Línea ' || src.line || ' contiene INS_GE_TAUXIL: ' || v_upper_line);
                END IF;
                */

                -- DETECCIÓN OPTIMIZADA DE SUBPROGRAMAS usando DBA_PROCEDURES
                IF REGEXP_LIKE(v_upper_line, '^\s*(PROCEDURE|FUNCTION)\s+[A-Z_][A-Z0-9_]*') THEN
                    DECLARE
                        v_temp_subprogram VARCHAR2(128);
                    BEGIN
                        v_temp_subprogram := REGEXP_SUBSTR(v_upper_line, '^\s*(PROCEDURE|FUNCTION)\s+([A-Z_][A-Z0-9_]*)', 1, 1, NULL, 2);
                        IF v_package_subprograms.EXISTS(UPPER(v_temp_subprogram)) THEN
                            v_subprogram := v_temp_subprogram;
                            v_subprograms_found := v_subprograms_found + 1;
                            --DBMS_OUTPUT.PUT_LINE('*** PROCESANDO: ' || v_subprogram || ' (línea ' || src.line || ')');
                        END IF;
                    END;
                END IF;

                -- Solo procesar dependencias si tenemos un subprograma válido
                IF v_subprogram IS NOT NULL THEN
                /*    
                IF INSTR(v_upper_line, 'INS_GE_TAUXIL') > 0 THEN
                    DBMS_OUTPUT.PUT_LINE('DEBUG2:  Línea ' || src.line || ' contiene INS_GE_TAUXIL: ' || v_upper_line);
                END IF;
                */
                    -- DETECCIÓN DML - PATRONES CORREGIDOS
                    
                    -- INSERT INTO - Patrón corregido para capturar grupo 1
                    IF REGEXP_LIKE(v_upper_line, 'INSERT\s+INTO\s+[A-Z_][A-Z0-9_]*') THEN
                        DECLARE
                            v_table VARCHAR2(128);
                        BEGIN
                            -- Corregido: capturar el grupo 1 (el nombre de la tabla)
                            v_table := REGEXP_SUBSTR(v_upper_line, 'INSERT\s+INTO\s+([A-Z_][A-Z0-9_]*)', 1, 1, NULL, 1);
                            
                            IF v_table IS NOT NULL AND NOT is_reserved_word(v_table) THEN
                                add_row(obj.owner, obj.object_name, obj.object_type, v_subprogram,
                                    NULL, v_table, NULL, 'TABLE', 'INSERT');
                            END IF;
                        END;
                    END IF;
                    
                    -- UPDATE - Patrón corregido
                    IF REGEXP_LIKE(v_upper_line, 'UPDATE\s+[A-Z_][A-Z0-9_]*') THEN
                        DECLARE
                            v_table VARCHAR2(128);
                        BEGIN
                            -- Corregido: capturar el grupo 1 (el nombre de la tabla)
                            v_table := REGEXP_SUBSTR(v_upper_line, 'UPDATE\s+([A-Z_][A-Z0-9_]*)', 1, 1, NULL, 1);
                            
                            IF v_table IS NOT NULL AND NOT is_reserved_word(v_table) THEN
                                add_row(obj.owner, obj.object_name, obj.object_type, v_subprogram,
                                    NULL, v_table, NULL, 'TABLE', 'UPDATE');
                            END IF;
                        END;
                    END IF;
                    
                    -- DELETE FROM - Patrón corregido
                    IF REGEXP_LIKE(v_upper_line, 'DELETE\s+FROM\s+[A-Z_][A-Z0-9_]*') THEN
                        DECLARE
                            v_table VARCHAR2(128);
                        BEGIN
                            -- Corregido: capturar el grupo 1 (el nombre de la tabla)
                            v_table := REGEXP_SUBSTR(v_upper_line, 'DELETE\s+FROM\s+([A-Z_][A-Z0-9_]*)', 1, 1, NULL, 1);
                            
                            IF v_table IS NOT NULL AND NOT is_reserved_word(v_table) THEN
                                add_row(obj.owner, obj.object_name, obj.object_type, v_subprogram,
                                    NULL, v_table, NULL, 'TABLE', 'DELETE');
                            END IF;
                        END;
                    END IF;
                    
                    -- SELECT FROM - Patrón corregido
                    IF REGEXP_LIKE(v_upper_line, 'FROM\s+[A-Z_][A-Z0-9_]*') THEN
                        DECLARE
                            v_table VARCHAR2(128);
                        BEGIN
                            -- Corregido: capturar el grupo 1 (el nombre de la tabla)
                            v_table := REGEXP_SUBSTR(v_upper_line, 'FROM\s+([A-Z_][A-Z0-9_]*)', 1, 1, NULL, 1);
                            
                            IF v_table IS NOT NULL AND NOT is_reserved_word(v_table) THEN
                                add_row(obj.owner, obj.object_name, obj.object_type, v_subprogram,
                                    NULL, v_table, NULL, 'TABLE', 'SELECT');
                            END IF;
                        END;
                    END IF;

                    -- LLAMADAS EXTERNAS package.procedure() - OPTIMIZADO CON BULK PROCESSING
                    DECLARE
                        v_package VARCHAR2(128);
                        v_proc VARCHAR2(128);
                        v_pos NUMBER := 1;
                        v_match_start NUMBER;
                        v_full_match VARCHAR2(200);
                        v_point_pos NUMBER;
                        v_paren_pos NUMBER;
                        
                        TYPE t_call_rec IS RECORD (
                            package_name VARCHAR2(128),
                            proc_name VARCHAR2(128)
                        );
                        TYPE t_call_tab IS TABLE OF t_call_rec;
                        v_calls t_call_tab := t_call_tab();
                    BEGIN
                        -- Buscar todas las llamadas externas Package.Procedure(
                        LOOP
                            -- Buscar el patrón desde la posición actual usando patrón precompilado
                            v_match_start := REGEXP_INSTR(v_upper_line, v_ext_call_pattern, v_pos);
                            EXIT WHEN v_match_start = 0;
                            
                            -- Extraer la coincidencia completa
                            v_full_match := REGEXP_SUBSTR(v_upper_line, '\b[A-Z_][A-Z0-9_]*\.[A-Z_][A-Z0-9_]*\s*\(', v_match_start);
                            
                            IF v_full_match IS NOT NULL THEN
                                -- Método manual más confiable: buscar posiciones del punto y paréntesis
                                v_point_pos := INSTR(v_full_match, '.');
                                v_paren_pos := INSTR(v_full_match, '(');
                                
                                IF v_point_pos > 1 AND v_paren_pos > v_point_pos THEN
                                    -- Extraer package (desde el inicio hasta el punto)
                                    v_package := TRIM(SUBSTR(v_full_match, 1, v_point_pos - 1));
                                    
                                    -- Extraer procedure (desde después del punto hasta el paréntesis)
                                    v_proc := TRIM(SUBSTR(v_full_match, v_point_pos + 1, v_paren_pos - v_point_pos - 1));
                                    
                                    -- Debug específico
                                    /*
                                    IF v_package LIKE '%QDIGITO%' OR v_proc LIKE '%CALCULA%' THEN
                                        DBMS_OUTPUT.PUT_LINE('FULL_MATCH: [' || v_full_match || ']');
                                        DBMS_OUTPUT.PUT_LINE('POINT_POS: ' || v_point_pos || ', PAREN_POS: ' || v_paren_pos);
                                        DBMS_OUTPUT.PUT_LINE('EXTRACTED PACKAGE: [' || NVL(v_package, 'NULL') || ']');
                                        DBMS_OUTPUT.PUT_LINE('EXTRACTED PROC: [' || NVL(v_proc, 'NULL') || ']');
                                    END IF;
                                    */
                                    -- Validar y procesar solo si ambos valores son válidos
                                    IF v_package IS NOT NULL AND v_proc IS NOT NULL AND 
                                       LENGTH(v_package) >= 3 AND LENGTH(v_proc) >= 3 AND
                                       NOT is_reserved_word(v_package) AND NOT is_reserved_word(v_proc) THEN
                                        -- Almacenar para procesamiento en lote
                                        v_calls.EXTEND;
                                        v_calls(v_calls.COUNT) := t_call_rec(v_package, v_proc);
                                    END IF;
                                END IF;
                            END IF;
                            
                            -- Avanzar posición después del match actual
                            v_pos := v_match_start + NVL(LENGTH(v_full_match), 1);
                            
                            -- Seguridad: evitar bucle infinito
                            EXIT WHEN v_pos > LENGTH(v_upper_line);
                        END LOOP;
                        
                        -- Procesamiento en lote para mejorar rendimiento
                        IF v_calls.COUNT > 0 THEN
                            FOR i IN 1..v_calls.COUNT LOOP
                                add_row(obj.owner, obj.object_name, obj.object_type, v_subprogram,
                                    NULL, v_calls(i).package_name, v_calls(i).proc_name, 'PACKAGE', 'CALL');
                            END LOOP;
                        END IF;
                    END;

                    -- DEBUG: solo si la línea contiene UPPER(INS_GE_TAUXIL)
                    /*
                    IF INSTR(v_upper_line, UPPER('INS_GE_TAUXIL')) > 0 THEN
                        DBMS_OUTPUT.PUT_LINE('DEBUG PRE-IF: línea ' || src.line || ' contiene UPPER(INS_GE_TAUXIL): ' || v_upper_line);
                    END IF;
                    */
                    -- LLAMADAS INTERNAS - USANDO DBA_PROCEDURES PARA PRECISIÓN MÁXIMA
                    IF REGEXP_LIKE(v_upper_line, '[A-Z_][A-Z0-9_]*\s*\(') THEN
                        DECLARE
                            v_pos NUMBER := 1;
                            v_match VARCHAR2(128);
                            -- Collection para acumular llamadas y procesarlas en lote
                            TYPE t_internal_call_rec IS RECORD (
                                proc_name VARCHAR2(128)
                            );
                            TYPE t_internal_call_tab IS TABLE OF t_internal_call_rec;
                            v_internal_calls_list t_internal_call_tab := t_internal_call_tab();
                        BEGIN
                            LOOP
                                /*
                                -- DEBUG: mostrar info si la línea contiene INS_GE_TAUXIL
                                IF INSTR(v_upper_line, 'INS_GE_TAUXIL') > 0 THEN
                                    DBMS_OUTPUT.PUT_LINE('DEBUG INTERNAL CALL: línea ' || src.line || ' contiene INS_GE_TAUXIL. subprogram=' || NVL(v_subprogram,'NULL') || ', match=' || NVL(v_match,'NULL'));
                                    DBMS_OUTPUT.PUT_LINE('DEBUG INTERNAL CALL1: v_upper_line=' || v_upper_line|| ', v_call_pattern=' || v_call_pattern || ', v_pos=' || v_pos);
                                END IF;
                                */
                                v_match := REGEXP_SUBSTR(v_upper_line, v_call_pattern, v_pos, 1, NULL, 1);
                                EXIT WHEN v_match IS NULL;

                                -- DEBUG: mostrar info si la línea contiene INS_GE_TAUXIL
                                /*
                                IF INSTR(v_upper_line, 'INS_GE_TAUXIL') > 0 THEN
                                    DBMS_OUTPUT.PUT_LINE('DEBUG INTERNAL CALL2: línea ' || src.line || ' contiene INS_GE_TAUXIL. subprogram=' || NVL(v_subprogram,'NULL') || ', match=' || NVL(v_match,'NULL'));
                                END IF;
                                */
                                -- Verificar usando DBA_PROCEDURES (más preciso)
                                IF -- comparación eliminada: ahora se registran todas las llamadas internas, incluyendo recursivas
                                   NOT is_reserved_word(v_match) AND 
                                   is_package_subprogram(v_match) THEN
                                    -- Acumular para procesamiento en lote
                                    v_internal_calls_list.EXTEND;
                                    v_internal_calls_list(v_internal_calls_list.COUNT) := t_internal_call_rec(v_match);
                                END IF;

                                v_pos := REGEXP_INSTR(v_upper_line, v_call_pattern, v_pos) + 1;
                                EXIT WHEN v_pos = 1;
                            END LOOP;
                            
                            -- Procesar todas las llamadas internas acumuladas en un lote
                            FOR i IN 1..v_internal_calls_list.COUNT LOOP
                                -- CORREGIDO: ahora se pasa el nombre del procedimiento llamado en called_subprogram
                                add_row(obj.owner, obj.object_name, obj.object_type, v_subprogram,
                                    obj.owner, obj.object_name, v_internal_calls_list(i).proc_name, 
                                    get_subprogram_type(v_internal_calls_list(i).proc_name), 'CALL');
                            END LOOP;
                        END;
                    END IF;
                END IF;
                
            EXCEPTION
                WHEN OTHERS THEN
                    DBMS_OUTPUT.PUT_LINE('ERROR línea ' || src.line || ': ' || SQLERRM);
            END;
        END LOOP;
        
        END; -- Cierre del bloque DECLARE para el procesamiento de código fuente
    END;
        
    -- ESTADÍSTICAS FINALES
        DBMS_OUTPUT.PUT_LINE('=== ESTADÍSTICAS FINALES ===');
        DBMS_OUTPUT.PUT_LINE('Total líneas analizadas: ' || v_total_lines);
        DBMS_OUTPUT.PUT_LINE('Líneas procesadas: ' || v_processed_lines);
        DBMS_OUTPUT.PUT_LINE('Subprogramas en DBA_PROCEDURES: ' || v_package_subprograms.COUNT);
        DBMS_OUTPUT.PUT_LINE('Subprogramas procesados: ' || v_subprograms_found);
        DBMS_OUTPUT.PUT_LINE('Total dependencias encontradas: ' || v_dependencies_found);
        DBMS_OUTPUT.PUT_LINE('  - Llamadas internas: ' || v_internal_calls);
        DBMS_OUTPUT.PUT_LINE('  - Llamadas externas: ' || v_external_calls);
        DBMS_OUTPUT.PUT_LINE('  - Operaciones DML: ' || (v_dependencies_found - v_internal_calls - v_external_calls));
        
        -- MOSTRAR SUBPROGRAMAS ENCONTRADOS EN DBA_PROCEDURES
        DBMS_OUTPUT.PUT_LINE('=== SUBPROGRAMAS DESDE DBA_PROCEDURES ===');
        DECLARE
            v_name VARCHAR2(128);
        BEGIN
            v_name := v_package_subprograms.FIRST;
            WHILE v_name IS NOT NULL LOOP
                --DBMS_OUTPUT.PUT_LINE('  ' || v_name || ' (' || v_package_subprograms(v_name).object_type || ')');
                v_name := v_package_subprograms.NEXT(v_name);
            END LOOP;
        END;
        
    END LOOP;
    
    -- Verificar si encontramos el objeto
    IF SQL%ROWCOUNT = 0 THEN
        DBMS_OUTPUT.PUT_LINE('⚠️  ADVERTENCIA: No se encontró el objeto VU_SFI.SF_QPORTAL_WEB_TRANV2');
        DBMS_OUTPUT.PUT_LINE('Verificando objetos disponibles...');
        
        FOR check_obj IN (
            SELECT owner, object_name, object_type
            FROM dba_objects
            WHERE (owner = 'VU_SFI' OR object_name LIKE '%QPORTAL%')
            AND object_type = 'PACKAGE BODY'
            ORDER BY owner, object_name
        ) LOOP
            DBMS_OUTPUT.PUT_LINE('Disponible: ' || check_obj.owner || '.' || check_obj.object_name);
        END LOOP;
    END IF;
    
    DBMS_OUTPUT.PUT_LINE('=== ANÁLISIS COMPLETADO ===');
    COMMIT;
    
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('ERROR GENERAL: ' || SQLERRM);
        ROLLBACK;
        RAISE;
END;
/

   
        
-- =====================================================
-- QUERY PARA MOSTRAR ÁRBOL COMPLETO DE DEPENDENCIAS
-- =====================================================

-- Query to find dependency paths from origin procedure to destination object
-- Uses recursive CTE to traverse the dependency chain
/*
WITH  dependency_paths (
    object_owner,
    object_name,
    object_type,
    subprogram,
    called_owner,
    called_object,
    called_subprogram,
    called_type,
    operation,
    level_depth,
    path_origin,
    path_destination,
    full_path,
    visited_nodes
) AS  (
    -- Start from the origin subprogram
    SELECT 
        object_owner,
        object_name,
        object_type,
        subprogram,
        called_owner,
        called_object,
        called_subprogram,
        called_type,
        operation,
        1 AS level_depth,
        object_owner || '.' || object_name || 
        CASE WHEN subprogram IS NOT NULL THEN '.' || subprogram ELSE '' END AS path_origin,
        NVL(called_owner || '.', '') || called_object || 
        CASE WHEN called_subprogram IS NOT NULL THEN '.' || called_subprogram ELSE '' END AS path_destination,
        object_owner || '.' || object_name || 
        CASE WHEN subprogram IS NOT NULL THEN '.' || subprogram ELSE '' END || ' -> ' ||
        NVL(called_owner || '.', '') || called_object || 
        CASE WHEN called_subprogram IS NOT NULL THEN '.' || called_subprogram ELSE '' END AS full_path,
        '|' || object_owner || '.' || object_name || 
        CASE WHEN subprogram IS NOT NULL THEN '.' || subprogram ELSE '' END || '|' AS visited_nodes
    FROM OBJ_DEPENDENCIES_EXPORT
    WHERE object_owner = :origin_owner
      AND object_name = :origin_object
      AND subprogram = :origin_subprogram
    UNION ALL
    -- Recursively find next level dependencies
    SELECT 
        dep.object_owner,
        dep.object_name,
        dep.object_type,
        dep.subprogram,
        dep.called_owner,
        dep.called_object,
        dep.called_subprogram,
        dep.called_type,
        dep.operation,
        dp.level_depth + 1,
        dp.path_origin,
        NVL(dep.called_owner || '.', '') || dep.called_object || 
        CASE WHEN dep.called_subprogram IS NOT NULL THEN '.' || dep.called_subprogram ELSE '' END,
        dp.full_path || ' -> ' ||
        NVL(dep.called_owner || '.', '') || dep.called_object || 
        CASE WHEN dep.called_subprogram IS NOT NULL THEN '.' || dep.called_subprogram ELSE '' END,
        dp.visited_nodes || 
        NVL(dep.called_owner || '.', '') || dep.called_object || 
        CASE WHEN dep.called_subprogram IS NOT NULL THEN '.' || dep.called_subprogram ELSE '' END || '|'
    FROM OBJ_DEPENDENCIES_EXPORT dep
    INNER JOIN dependency_paths dp ON (
        dep.object_owner = NVL(dp.called_owner, dp.object_owner)
        AND dep.object_name = dp.called_object
        AND dep.subprogram = dp.called_subprogram
        AND dep.subprogram <> dp.subprogram
    )
    WHERE dp.level_depth < 10
      AND dp.visited_nodes NOT LIKE '%|' || 
          NVL(dep.called_owner || '.', '') || dep.called_object || 
          CASE WHEN dep.called_subprogram IS NOT NULL THEN '.' || dep.called_subprogram ELSE '' END || '|%'
)
SELECT DISTINCT
    level_depth,
    path_origin,
    path_destination,
    full_path,
    operation,
    called_type
FROM dependency_paths
ORDER BY level_depth, full_path;

-- Alternative simpler version for specific path finding
-- Replace the bind variables with actual values

-- Example usage:
/*
-- Find all paths from VU_SFI.SF_QPORTAL_WEB_TRANV2.SPECIFIC_PROC to any table
WITH RECURSIVE dependency_paths AS (
    SELECT 
        object_owner, object_name, object_type, subprogram,
        called_owner, called_object, called_subprogram, 
        called_type, operation,
        1 as level_depth,
        object_owner || '.' || object_name || 
        CASE WHEN subprogram IS NOT NULL THEN '.' || subprogram ELSE '' END ||
        ' -> ' ||
        NVL(called_owner || '.', '') || called_object || 
        CASE WHEN called_subprogram IS NOT NULL THEN '.' || called_subprogram ELSE '' END as full_path
    FROM OBJ_DEPENDENCIES_EXPORT
    WHERE object_owner = 'VU_SFI' 
      AND object_name = 'SF_QPORTAL_WEB_TRANV2'
      AND subprogram = 'YOUR_PROCEDURE_NAME'
    
    UNION ALL
    
    SELECT 
        dep.object_owner, dep.object_name, dep.object_type, dep.subprogram,
        dep.called_owner, dep.called_object, dep.called_subprogram, 
        dep.called_type, dep.operation,
        dp.level_depth + 1,
        dp.full_path || ' -> ' ||
        NVL(dep.called_owner || '.', '') || dep.called_object || 
        CASE WHEN dep.called_subprogram IS NOT NULL THEN '.' || dep.called_subprogram ELSE '' END
    FROM OBJ_DEPENDENCIES_EXPORT dep
    INNER JOIN dependency_paths dp ON (
        dep.object_owner = NVL(dp.called_owner, dp.object_owner)
        AND dep.object_name = dp.called_object
        AND (dep.subprogram = dp.called_subprogram OR 
             (dep.subprogram IS NULL AND dp.called_subprogram IS NULL))
    )
    WHERE dp.level_depth < 5
)
SELECT 
    level_depth,
    full_path,
    operation,
    called_type as destination_type
FROM dependency_paths
WHERE called_type = 'TABLE'  -- Only show paths ending at tables
ORDER BY level_depth, full_path;
*/
-- Opcional: Consulta detallada de dependencias
/*
SELECT *
FROM OBJ_DEPENDENCIES_EXPORT 
WHERE subprogram = 'INS_GE_TAUXIL'
AND CALLED_SUBPROGRAM = 'INS_GE_TAUXIL'
ORDER BY subprogram, called_type, called_object;

TRUNCATE TABLE OBJ_DEPENDENCIES_EXPORT;

*/

-- Consulta detallada para verificar llamadas internas detectadas
/*
SELECT *
FROM OBJ_DEPENDENCIES_EXPORT
where called_subprogram = 'GE_TAUXIL'
AND object_name = 'SF_QPORTAL_WEB_TRANV2'
  AND subprogram = 'VALIDAR_DATOS_ENTRADA'
  AND called_subprogram = 'INS_GE_TAUXIL'
ORDER BY subprogram, called_type, called_object;
*/