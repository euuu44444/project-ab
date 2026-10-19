// Reconstruct the uploaded reference in memory from its original generator
// and engine. The large mobile baseline is already part of the source tree.
const fs=require('fs'),path=require('path'),assert=require('assert/strict'),crypto=require('crypto');
module.exports=function referenceHtml(){
 const root=path.resolve(__dirname,'../..');let html=null;
 const referenceFs={...fs,
  readFileSync(filename,encoding){
   const name=path.basename(filename),reference={
    'frame-generation-runtime.js':'fg3-frame-generation-runtime.js',
    'frame-synthesis.js':'fg3-frame-synthesis.js'
   }[name];
   return fs.readFileSync(reference?path.join(__dirname,reference):filename,encoding);
  },
  writeFileSync(filename,value){
   assert.equal(path.resolve(filename),path.join(root,'app/src/main/assets/index.html'));
   html=value;
  }
 };
 const generator=fs.readFileSync(path.join(__dirname,'fg3-build-frame-generation.cjs'),'utf8');
 const load=name=>name==='fs'?referenceFs:require(name);
 new Function('require','__dirname','console',generator)(load,path.join(root,'frame_generation'),{log(){}});
 assert.equal(typeof html,'string');
 assert.equal(crypto.createHash('sha256').update(html).digest('hex'),'1b9ee47a7e77ff0e445a33af050688df8af1280960b04259bb00816215b6570c','Reference must match the uploaded fg.3 HTML');
 return html;
};
