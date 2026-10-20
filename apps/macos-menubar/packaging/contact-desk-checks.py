#!/usr/bin/env python3
"""Synthetic full-directory and on-demand history boundary checks; no network or send."""
import importlib.util, json, tempfile, unittest
from pathlib import Path
spec=importlib.util.spec_from_file_location('reader',Path(__file__).resolve().parents[1]/'Sources/MurmurMenuBar/Resources/mesh-comms-query.py')
Q=importlib.util.module_from_spec(spec);spec.loader.exec_module(Q)

class ContactDeskTests(unittest.TestCase):
    def test_current_roster_unions_eight_external_contacts_including_unbound(self):
        linked=['anca','vasiliev','dan','ira','mykhailo','kirill_oleinichenko']
        data={'privacy':'owner-metadata','people':[
            {'id':'person:'+pid,'agents':['agent-'+pid],'writable_agents':['agent-'+pid]} for pid in linked]}
        current=linked+['olya','ilia','alex']
        people={'privacy':'operator_metadata_only_tailnet','people':[
            {'id':'person:'+pid,'name':'Synthetic '+pid,'history':False} for pid in current],
            'bindings':[{'person':'person:alex','agent':'shaper-viola'}]}
        result=Q.add_roster(data,people,{'privacy':'metadata-only'})
        self.assertEqual({p['id'] for p in result['people']},{'person:'+pid for pid in linked+['olya','ilia']})
        for row in result['people'][-2:]:
            self.assertEqual((row['agents'],row['writable_agents'],row['contact_state']),([],[],'unlinked'))
        result=Q.add_flows(result,{'privacy':'metadata-only','sources':[]})
        for row in result['people'][-2:]:self.assertEqual(row['flows'],{})

    def test_flow_source_receipts_are_content_free_and_additive(self):
        data={'privacy':'owner-metadata','people':[]}
        share={'privacy':'metadata-only','sources':[
            {'store':'ordinary','ok':False,'observed_at':'2026-10-20T12:00:00Z','error':'PRIVATE ERROR','path':'/private/path'},
            {'store':'second','ok':'unknown','observed_at':'PRIVATE TIME'},
            {'store':'../private','ok':True}], 'truncated':False}
        result=Q.add_flows(data,share)
        self.assertEqual(result['flow_sources'],[
            {'store':'ordinary','ok':False,'observed_at':'2026-10-20T12:00:00Z'},
            {'store':'second','ok':None}])
        self.assertNotIn('PRIVATE',json.dumps(result))
        self.assertNotIn('/private',json.dumps(result))

    def test_flow_sources_preserve_unknown_zero_and_private_boundary(self):
        data={'privacy':'owner-metadata','people':[
            {'id':'person:ordinary','agents':['agent-demo']},
            {'id':'person:private','agents':['shaper-viola'],'contact_state':'status_only'}]}
        share={'privacy':'metadata-only','ts':'2026-10-20T12:00:00Z','sources':[{'store':'ordinary','ok':False}],'messages':[],'truncated':False}
        result=Q.add_flows(data,share)
        self.assertIsNone(result['people'][0]['flows']['agent-demo']['inbound_count'])
        self.assertNotIn('flows',result['people'][1])
        share['sources'][0]['ok']=True
        result=Q.add_flows(data,share)
        self.assertEqual(result['people'][0]['flows']['agent-demo']['inbound_count'],0)
        self.assertNotIn('flows',result['people'][1])

    def test_full_directory_keeps_quiet_contacts_without_grants(self):
        data={'privacy':'owner-metadata','people':[{'id':'person:connected','agents':['agent-demo'],'writable_agents':['agent-demo']}]}
        people={'privacy':'operator_metadata_only_tailnet','observed_at':'2026-10-11T12:00:00Z','people':[{'id':'person:connected'},{'id':'person:quiet','name':'Quiet'},{'id':'person:former','history':True},{'id':'person:private','name':'Hidden'}], 'bindings':[{'person':'person:private','agent':'custom-private'}]}
        share={'privacy':'metadata-only','private_contours':[{'peer_identity':'custom-private','privacy':'status-only'}]}
        result=Q.add_roster(data,people,share)
        self.assertEqual([p['id'] for p in result['people']],['person:connected','person:quiet'])
        self.assertEqual(result['people'][1]['writable_agents'],[])
        self.assertEqual(result['people'][0]['writable_agents'],['agent-demo'])
        self.assertEqual(result['roster_at'],people['observed_at'])

    def test_unsafe_roster_rejected(self):
        with self.assertRaises(ValueError):Q.add_roster({'privacy':'owner-metadata','people':[]},{'privacy':'public'},{'privacy':'metadata-only'})

    def test_fresh_private_contours_remove_stale_attention_before_projection(self):
        def item(key, peer, source):
            return {'id':key,'peer':peer,'kind':'owner','title':'Synthetic '+key,
                    'next_action':'Review synthetic source','source_ids':[source],
                    'conversation':'dm:synthetic','actionable':True,'alert':True}
        allowed=item('ordinary','agent-demo','ordinary-source')
        data={'privacy':'owner-metadata','people':[],
              'attention':{'schema':1,'receipts_ok':True,
                           'items':[allowed,item('private-peer','custom-private','peer-source'),
                                    item('private-local','agent-demo','private-source')],
                           'counts':{'owner':3},'actionable_count':3}}
        share={'privacy':'metadata-only',
               'private_contours':[{'id':'private','privacy':'status-only',
                                    'peer_identity':'custom-private','local_identity':'local-private'}],
               'messages':[{'id':'private-source','peer_identity':'agent-demo','local_identity':'local-private'}]}
        result=Q.augment(data,{'privacy':'operator-only-metadata'},share)
        self.assertEqual(result['attention']['items'],[allowed])
        self.assertEqual(result['attention']['counts'],{'owner':1})
        self.assertEqual(result['attention']['actionable_count'],1)
        self.assertNotIn('Synthetic private',json.dumps(result))

    def test_status_only_person_never_carries_attention(self):
        data={'privacy':'owner-metadata',
              'people':[{'id':'person:private','agents':['status-only-peer'],'contact_state':'status_only'}],
              'attention':{'schema':1,'receipts_ok':True,'items':[
                  {'id':'private','peer':'status-only-peer','kind':'owner','source_ids':[],
                   'title':'Synthetic hidden title','actionable':True,'alert':True}]}}
        result=Q.augment(data,{'privacy':'operator-only-metadata'},{'privacy':'metadata-only'})
        self.assertEqual(result['attention']['items'],[])
        self.assertNotIn('Synthetic hidden title',json.dumps(result))

    def test_history_exact_peer_store_dedup_and_no_bodies(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            msg={'store':'ordinary','id':'one','peer_identity':'agent-demo','local_identity':'agent-owner','date':'2026-10-11T12:00:00Z','direction':'inbound','text':'DO NOT EXPOSE THIS'}
            share={'privacy':'metadata-only','messages':[msg,msg,{**msg,'store':'private-store','id':'other'},{**msg,'id':'two','peer_identity':'someone-else'},{**msg,'id':'three','local_identity':'custom-private'}], 'private_contours':[{'local_identity':'custom-private','peer_identity':'private-peer'}]}
            (root/'share-data.json').write_text(json.dumps(share))
            result=Q.contact_history('agent-demo',root,{'ordinary':None})
            self.assertEqual(result['total'],1);self.assertEqual(result['matches'][0]['id'],'one')
            self.assertNotIn('DO NOT EXPOSE',json.dumps(result))
            for peer in ('private-peer','agent-viola-alex','../../bad'):
                with self.assertRaises(ValueError):Q.contact_history(peer,root,{'ordinary':None})
            share['privacy']='public';(root/'share-data.json').write_text(json.dumps(share))
            with self.assertRaises(ValueError):Q.contact_history('agent-demo',root,{'ordinary':None})

    def test_history_bounded(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);(root/'share-data.json').write_text(json.dumps({'privacy':'metadata-only','messages':[{'id':str(i),'store':'ordinary','peer_identity':'agent-demo','date':f'2026-10-11T12:00:{i:02d}Z'} for i in range(55)]}))
            r=Q.contact_history('agent-demo',root,{'ordinary':None});self.assertEqual(len(r['matches']),40);self.assertEqual(r['total'],55);self.assertTrue(r['truncated'])

if __name__=='__main__':unittest.main()
