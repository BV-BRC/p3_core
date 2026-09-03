import os
import sys
import re
import requests
import io
import urllib.request, urllib.parse, urllib.error
import json
import pandas as pd
from requests.packages.urllib3.exceptions import InsecureRequestWarning
requests.packages.urllib3.disable_warnings(InsecureRequestWarning)

Debug = False #shared across functions defined here
LOG = sys.stderr
Base_url = "https://www.bv-brc.org/api-internal/"

PatricUser = None

# First iteration: include getFeatureDataFrame, getSubsystemsDataFrame, getPathwayDataFrame, authenticate functions and getGenomeGroupIds

# splits a list into multiple lists of max size == size
def chunker(seq, size):
    return (seq[pos:pos + size] for pos in range(0, len(seq), size))

# Given a query, returns an iterator over each line of the result
def getQueryData(base, query, headers):
        print('Base = {0}\nQuery = {1}\nHeaders = {2}'.format(base,query,headers))
        with requests.post(url=base, data=query, headers=headers) as r:
            if r.encoding is None:
                r.encoding = "utf-8"
            if not r.ok:
                print (r.reason)
                sys.stderr.write("Error in API request \n")
                return None
            for line in r.iter_lines(decode_unicode=True):
                yield line

# Given a query, returns all the response text 
def getQueryDataText(base, query, headers, print_query = True):
        if print_query:
            print('Base = {0}\nQuery = {1}\nHeaders = {2}'.format(base,query,headers))
        with requests.post(url=base, data=query, headers=headers) as r:
            if r.encoding is None:
                r.encoding = "utf-8"
            if not r.ok:
                sys.stderr.write("Error in API request \n")
            #for line in r.iter_lines(decode_unicode=True):
            #    yield line
            return r.text

# Given a set of genome_ids, returns a pandas dataframe after querying for features
def getFeatureDataFrame(genome_ids, session, limit=2500000):
    dtype_dict = {'genome_id': str,
                  'PATRIC genus-specific families (PLfams)':'category',
                  'PATRIC cross-genus families (PGfams)':'category',
                  'plfam_id': 'category',
                  'pgfam_id': 'category'}
    feature_df_list = []
    limit = "limit({0})".format(limit)
    for gids in chunker(genome_ids, 20):
        batch=""
        genomes = "in(genome_id,({0}))".format(','.join(gids))
        select = "sort(+feature_id)&eq(annotation,PATRIC)"
        base = "https://www.patricbrc.org/api/genome_feature/?http_download=true"
        query = "&".join([genomes,limit,select]) 
        headers = {"accept":"text/tsv", "content-type":"application/rqlquery+x-www-form-urlencoded", 'Authorization': session.headers['Authorization']}
        #query = requests.get(f"https://www.patricbrc.org/api/genome_feature/?in(genome_id,({','.join(gids)}))&eq(annotation,PATRIC)&limit({limit})&sort(+genome_id)&http_download=true&http_accept=text/tsv")

        print('Query = {0}\nHeaders = {1}'.format(base+'&'+query,headers))
        with requests.post(url=base, data=query, headers=headers) as r:
            if r.encoding is None:
                r.encoding = "utf-8"
            if not r.ok:
                sys.stderr.write("Error in API request \n")
            batch_count=0
            for line in r.iter_lines(decode_unicode=True):
                line = line+'\n'
                batch+=line
                batch_count+=1        
        # TODO: set column data types
        if batch == '':
            continue
        feature_df = pd.read_csv(io.StringIO(batch),sep='\t',dtype=dtype_dict)
        feature_df_list.append(feature_df)
    if len(feature_df_list) > 0:
        return_df = pd.concat(feature_df_list) 
        return return_df
    else:
        return None

# Given a set of genome_ids, returns a pandas dataframe after querying for subsystems
def getSubsystemsDataFrame(genome_ids,session,limit=2500000):
    subsystem_df_list = []
    limit = "limit({0})".format(limit)
    for gids in chunker(genome_ids, 20):
        batch=""
        genomes = "in(genome_id,({0}))".format(','.join(gids))
        select = "sort(+id)"
        base = "https://alpha.bv-brc.org/api/subsystem/?http_download=true"
        query = "&".join([genomes,limit,select])
        headers = {"accept":"text/tsv", "content-type":"application/rqlquery+x-www-form-urlencoded", 'Authorization': session.headers['Authorization']}
        #subsystem_query = requests.get(f"https://patricbrc.org/api/subsystem/?in(genome_id,({','.join(gids)}))&limit({limit})&sort(+genome_id)&http_accept=text/tsv")
        #subsystem_df = pd.read_table(io.StringIO(subsystem_query.text),sep='\t')

        print('Query = {0}\nHeaders = {1}'.format(base+'&'+query,headers))
        with requests.post(url=base, data=query, headers=headers) as r:
            if r.encoding is None:
                r.encoding = "utf-8"
            if not r.ok:
                sys.stderr.write("Error in API request \n")
            batch_count=0
            for line in r.iter_lines(decode_unicode=True):
                line = line+'\n'
                batch+=line
                batch_count+=1
        # set column data types
        if batch == '':
            continue
        subsystem_df = pd.read_csv(io.StringIO(batch),sep='\t',dtype={'genome_id':str})
        subsystem_df_list.append(subsystem_df)
    if len(subsystem_df_list) > 0:
        return_df = pd.concat(subsystem_df_list)
        return return_df
    else:
        return None

# Given a set of genome_ids, returns a pandas dataframe after querying for pathways 
def getPathwayDataFrame(genome_ids,session,limit=2500000):
    print(f'executing getPathwayDataFrame with {len(genome_ids)} genome ids') 
    pathway_df_list = [] 
    for gids in chunker(genome_ids, 20):
        batch=""
        genomes = "in(genome_id,({0}))".format(','.join(gids))
        limit_str = "limit({0})".format(limit)
        select = "eq(annotation,PATRIC)&sort(+id)"
        base = "https://alpha.bv-brc.org/api/pathway/?http_download=true"
        query = "&".join([genomes,limit_str,select])
        headers = {"accept":"text/tsv", "content-type":"application/rqlquery+x-www-form-urlencoded", 'Authorization': session.headers['Authorization']}

        print('Query = {0}\nHeaders = {1}'.format(base+'&'+query,headers))
        with requests.post(url=base, data=query, headers=headers) as r:
            if r.encoding is None:
                r.encoding = "utf-8"
            if not r.ok:
                sys.stderr.write("Error in API request \n")
            batch_count=0
            for line in r.iter_lines(decode_unicode=True):
                line = line+'\n'
                batch+=line
                batch_count+=1 
        # TODO: set column data types
        if batch == '':
            continue
        pathway_df = pd.read_csv(io.StringIO(batch),sep='\t',dtype={'genome_id':str,'pathway_id':str})
        pathway_df_list.append(pathway_df)
    if len(pathway_df_list) > 0:
        return_df = pd.concat(pathway_df_list)
        return return_df
    else:
        return None

# athenticates session by searching for token file
def authenticateByFile(tokenFile=None, Session=None):
    if not tokenFile:
        tokenFile = os.path.join(os.environ.get('HOME'), ".patric_token")
    if os.path.exists(tokenFile):
        LOG.write("reading auth key from file %s\n"%tokenFile)
        with open(tokenFile) as F:
            tokenString = F.read().rstrip()
            authenticateByString(tokenString, Session)
        return True
    return False

# authenticates session by looking for KB_AUTH_TOKEN
def authenticateByEnv(Session):
    if "KB_AUTH_TOKEN" in os.environ:
        LOG.write("reading auth key from environment\n")
        authenticateByString(os.environ.get('KB_AUTH_TOKEN'), Session)
        return True
    else:
        return authenticateByFile(None, Session)

# authenticates session by analyzing input string
def authenticateByString(tokenString, Session):
    Session.headers.update({ 'Authorization' : tokenString })
    if "Authorization" in Session.headers:
        global PatricUser
        PatricUser = Session.headers["Authorization"].split(r"|")[3].split("=")[1]
        LOG.write("Patric user = %s\n"%PatricUser)

# Returns a list of genome_ids from the passed in genome group
# - NOTE: may stop returning after 25,000 genomes. Should there even be that many in a group?
def getGenomeIdsByGenomeGroup(genomeGroupName, Session, genomeGroupPath=False):
    if genomeGroupPath: #genomeGroupName is assumed to be a full path
        group_path = urllib.parse.quote(genomeGroupName)
        genomeGroupSpecifier = group_path.replace("/", "%2f")
    else: #assume the genome group is in /home/Genome Groups"
        genomeGroupSpecifier = PatricUser+"/home/Genome Groups/"+genomeGroupName
        genomeGroupSpecifier = "/"+urllib.parse.quote(genomeGroupSpecifier)
        genomeGroupSpecifier = genomeGroupSpecifier.replace("/", "%2f")
    query = "in(genome_id,GenomeGroup("+genomeGroupSpecifier+"))"
    query += "&select(genome_id)"
    query += "&limit(10000)"
    ret = Session.get(Base_url+"genome/", params=query)
    data = json.loads(ret.text) 
    ret_ids = [list(x.values())[0] for x in data]
    return ret_ids

# Returns a list of genome_ids from the passed in genus 
def getGenomeDataFrameByGenus(genus, Session, limit=50000):
    #select = f"eq(genus,{genus})&sort(+genome_name)&"
    query = f"eq(genus,{genus})&sort(+genome_id)"
    query += "&limit({0})".format(limit)
    # commented out section does not return all genome ids
    #base = "https://www.patricbrc.org/api/genome/?http_download=true"
    #ret = Session.get(Base_url+'genome/', params=query)
    #data = json.loads(ret.text)
    #ret_ids = [list(x.values())[0] for x in data]
    #return ret_ids
    base = Base_url + 'genome/?http_download=true'
    batch=""
    headers = {"accept":"text/tsv", "content-type":"application/rqlquery+x-www-form-urlencoded", 'Authorization': Session.headers['Authorization']}
    with requests.post(url=base, data=query, headers=headers) as r:
            if r.encoding is None:
                r.encoding = "utf-8"
            if not r.ok:
                sys.stderr.write("Error in API request \n")
            batch_count=0
            for line in r.iter_lines(decode_unicode=True):
                line = line+'\n'
                batch+=line
                batch_count+=1
    if batch == '':
        return None 
    genomes_df = pd.read_csv(io.StringIO(batch),sep='\t',dtype={'genome_id':str})
    return genomes_df

# Returns a list of genome_ids from the passed in genus 
def getGenomeDataFrameBySuperkingdom(Session, limit=2000000):
    #select = f"eq(genus,{genus})&sort(+genome_name)&"
    query = f"eq(superkingdom,Bacteria)&sort(+genome_id)"
    query += "&limit({0})".format(limit)
    # commented out section does not return all genome ids
    #base = "https://www.patricbrc.org/api/genome/?http_download=true"
    #ret = Session.get(Base_url+'genome/', params=query)
    #data = json.loads(ret.text)
    #ret_ids = [list(x.values())[0] for x in data]
    #return ret_ids
    base = Base_url + 'genome/?http_download=true'
    batch=""
    headers = {"accept":"text/tsv", "content-type":"application/rqlquery+x-www-form-urlencoded", 'Authorization': Session.headers['Authorization']}
    print('Query = {0}\nHeaders = {1}'.format(base+'&'+query,headers))
    with requests.post(url=base, data=query, headers=headers) as r:
            if r.encoding is None:
                r.encoding = "utf-8"
            if not r.ok:
                sys.stderr.write("Error in API request \n")
            batch_count=0
            for line in r.iter_lines(decode_unicode=True):
                line = line+'\n'
                batch+=line
                batch_count+=1
    if batch == '':
        return None 
    genomes_df = pd.read_csv(io.StringIO(batch),sep='\t',dtype={'genome_id':str})
    return genomes_df



def getDataForGenomes(genomeIdSet, Session):
    genome_df_list = []
    for gids in chunker(genomeIdSet, 20):
        query = "in(genome_id,(%s))"%",".join(gids)
        query += f"&sort(+genome_id)"
        query += "&limit(%s)"%len(gids)

        base = Base_url + 'genome/?http_download=true'
        batch=""
        headers = {"accept":"text/tsv", "content-type":"application/rqlquery+x-www-form-urlencoded", 'Authorization': Session.headers['Authorization']}
        print('Query = {0}\nHeaders = {1}'.format(base+'&'+query,headers))
        with requests.post(url=base, data=query, headers=headers) as r:
            if r.encoding is None:
                r.encoding = "utf-8"
            if not r.ok:
                sys.stderr.write("Error in API request \n")
            batch_count=0
            for line in r.iter_lines(decode_unicode=True):
                line = line+'\n'
                batch+=line
                batch_count+=1 
        # TODO: rename columns
        if batch == '':
            continue 
        genomes_df = pd.read_csv(io.StringIO(batch),sep='\t',dtype={'genome_id':str})
        genome_df_list.append(genomes_df)
    if len(genome_df_list) > 0:
        return_df = pd.concat(genome_df_list)
        return return_df
    else:
        None
